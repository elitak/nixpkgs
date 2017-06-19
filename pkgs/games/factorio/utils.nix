# This file provides a top-level function that will be used by both nixpkgs and nixos
# to generate mod directories for use at runtime by factorio.
{ stdenv
, writeScript
, runCommand
, callPackages
, curl
, nix
, gnused
, xz
, gnutar
}:
with stdenv.lib;
with {inherit (builtins) parseDrvName;};
let

  baseURL = https://mods.factorio.com;

  defaultHashCachePath = "/var/cache/factorio-mods-hashCache.nix";

  varsFromInfo = info: rec {
    urlPath = info.download_url;
    url = baseURL + info.download_url;
    zipName = info.file_name;
    modName = info.info_json.name;
    nixName = replaceStrings [" "] ["_"] modName;
    version = info.info_json.version;
    drvName = "${nixName}-${version}";
    cleanZipName = sanitizeZipName zipName;
  };

  sanitizeZipName = name:
    let splits = reverseList (splitString "_" (replaceStrings [" "] ["_"] name));
    in concatStringsSep "_" (reverseList ([(concatStringsSep "-" (reverseList (take 2 splits)))] ++ (drop 2 splits)));

in rec {

  inherit defaultHashCachePath;

  # TODO Ask devs to allow HTTP HEAD to provide the correct sha256 hash? That would eliminate the need for hashCache entirely.
  # NB the sha256 of this fetch changes every time, so just pass the date as the version to pin the drv daily
  modIndexDrv = version: stdenv.mkDerivation {
    name = "factorio-modIndex-${version}";
    buildInputs = [ curl ];
    preferLocalBuild = true;
    buildCommand = ''
      curl -k "${baseURL}/api/mods?page_size=max" > $out
    '';
  };

  # This is for use by the actual factorio derivations to create a directory of aggregated mods, to pass in as a command line arg
  mkModDirDrv = mods: # a list of mod derivations
    let
      recursiveDeps = modDrv: [modDrv] ++ optionals (modDrv.deps == []) (map recursiveDeps modDrv.deps);
      modDrvs = unique (flatten (map recursiveDeps mods));
    in
    stdenv.mkDerivation {
      name = "factorio-mod-directory";

      preferLocalBuild = true;
      buildCommand = ''
        mkdir -p $out
        for modDrv in ${toString modDrvs}; do
          # NB: there will only ever be a single zip file in each mod derivation's output dir
          ln -s $modDrv/*.zip $out
        done
      '';
    };

  mkDefaultNix = { releases
                 , hashCache
                 , version
                 }:
    let
      # This is a list series of attrsets, each with a nv-pair of drvNameWithoutVersion:drvNameWithVersion)
      versions = map (info: with varsFromInfo info; { "${(parseDrvName drvName).name}" = drvName; }) releases;
      # Here, we fold the above, keeping only the newest version as a value to the grouped keys (drvNameWithoutVersion)
      latestVersions = foldAttrs (latest: x: if versionOlder latest x then x else latest) "" versions;
      # This is the lookup function that will be passed to mkModMetaDrv, that creates the drv text for each modRelease (`info`)
      lookupLatestVersion = name: latestVersions.${name};
      fallbackURL = "https://factorio-mods.xor.us";
    in stdenv.mkDerivation {
    name = "factorio-mods-defaultNix-${version}";
    preferLocalBuild = true;
    passAsFile = [ "buildCommand" ];
    buildCommand = ''
      source $stdenv/setup
      cat <<EOF > $out
      { pkgs ? import <nixpkgs> { }
      , username ? null
      , token ? null
      }:
      with {
        inherit (pkgs) fetchurl;
        inherit (pkgs.lib) fix concatStringsSep tail splitString;
        inherit (pkgs.stdenv) mkDerivation;
      };
      let
        pathFromURL = url: concatStringsSep "/" (tail(tail(tail (splitString "/" url) )));
        fetchMod = args: fetchurl (args // (if (username != null && token != null)
          then { curlOpts = "-G --data username=\''${username} --data token=\''${token}"; }
          else { url = "${fallbackURL}/\''${pathFromURL args.url}"; }
        ));
      in fix (self: {
      ${concatMapStrings (mkModMetaDrv hashCache lookupLatestVersion) releases}
      })
      EOF
    '';
  };

  # This turns a single mod into its own .nix and imports it.
  # Currently this is only for testing purposes.
  mkModDrv = hashCache: lookupLatestVersion: info:
    with (varsFromInfo info);
    (import (pkgs.writeText "${drvName}.nix" ''
      {
      ${mkModMetaDrv hashCache lookupLatestVersion info}
      }
    '')).${drvName};

  # This makes a "meta-derivation", a string that can be put in a nix file and
  # later evaluated into a derivation for fetching the mod with or without
  # creds (set them to "" to use cached binary files only).
  mkModMetaDrv = hashCache: lookupLatestVersion: info:
      with (varsFromInfo info);
      let
        namePart = (parseDrvName drvName).name;
        latestVersion = lookupLatestVersion namePart;
        #parseDep = depStr: { name = splitString ">="
        #transformDeps = depList: transformDeps2 (if length depList < 1 then transformDeps2 [ depList ] else depList);
        #transformDeps = depList: "[ ${toString depList} ]"; # TODO
        transformDeps = depList: "[  ]"; # TODO
        # TODO maybe have dumb dep checking like just take the topmost version for each name as the dep
        # TODO parsing is complex: why sometimes a string and not a list?
        #                          >= somever ? another dep is conditional dep? i cant handle this well because i don't know what the client's "base" mod is ahead of time, nor do i really want a branching deptree in any given mod (different drvs given different other mods)
      in
      ''
        "${drvName}" = mkDerivation {
          name = "${drvName}";
          src = fetchMod {
            name = "${cleanZipName}";
            url = "${url}";
            sha256 = "${hashCache.${urlPath}}";
          };
          deps = ${transformDeps (attrByPath ["info_json" "dependencies"] [] info)};
          preferLocalBuild = true;
          buildCommand = '''
            mkdir -p \$out
            cp \$src \$out/"${zipName}"
          ''';
        };
        ${if latestVersion == drvName then "\"${namePart}\" = self.\"${drvName}\";\n" else ""}
      '';

  hashCacheUpdater = { releases
                     , hashCache
                     , username
                     , token
                     }: let
          # TODO check using nix-hash command all existing entries found in the store? This would avoid having to complete *all* fetches to save *any* new hash.
          # NOTE sometimes it seems like downloads happen twice, but that's usually just the lost old files with good hashes being refetched, not the newly cached ones
      prefetch = info: with varsFromInfo info; optionalString (! hashCache ? ${urlPath}) ''$( hash=$(${getBin nix}/bin/nix-prefetch-url --type sha256 --name "${cleanZipName}" "${url}?username=$username&token=$token"); if [[ $? -eq 0 ]]; then echo "\"${urlPath}\" = \"$hash\";"; else echo '# "${urlPath}" could not be fetched during the last attempt. Re-run the updater.'; fi )'';
    in writeScript "updateHashes.sh" ''
      username=${username}
      token=${token}
      cat <<EOF
      {
        ${concatStringsSep "\n  " (
          (mapAttrsToList (a: v: ''"${a}" = "${v}";'') hashCache)
          ++ (filter (a: a != "") (map prefetch releases))
        )
      }
      }
      EOF
    '';

  mkModsChannel = { defaultNix
                  , version
                  , binaryCacheURL ? null
                  }:
  let
    # HACK appending version only until newest nix is made stable that checks for name collision when unpacking channel
    channelName = "factorio-mods-${version}";
  in stdenv.mkDerivation {
    name = "factorio-mods-channel-${version}";
    preferLocalBuild = true;
    passAsFile = [ "buildCommand" ];
    buildInputs = [ xz gnutar ];
    buildCommand = ''
      mkdir -p ${channelName}
      cp ${defaultNix} ${channelName}/default.nix

      mkdir -p $out
      ${if binaryCacheURL != null then "echo -n ${binaryCacheURL} > $out/binary-cache-url" else ""}
      tar cJf $out/nixexprs.tar.xz ${channelName}
    '';
  };

  channel-management = { version # e.g.`--argstr version $(date +%Y.%m.%d)`
                       # e.g. `--arg username "with builtins; (fromJSON (readFile ~/.factorio/player-data.json)).service-username"`
                       , username ? null
                       # e.g. `--arg token "with builtins; (fromJSON (readFile ~/.factorio/player-data.json)).service-token"`
                       , token ? null
                       # The URL to have the channel point to use as the binary cache
                       , binaryCacheURL ? null
                       }:
  let
    modIndexJSON = modIndexDrv version;
    modIndex = builtins.fromJSON (readFile modIndexJSON);
    latestReleases =  map (a: a.latest_release) modIndex.results;

    hashCache = if pathExists defaultHashCachePath then import defaultHashCachePath else { };
  in rec {
    # Overview:
    #  hashCacheUpdater begets cache in /var/cache
    #  release builds default.nix from the manifest + cache that represents the factorio-mods channel
    #  that default.nix is used directly in configuration.nix's mods = with (import mods.nix); [ mod1 mod2 ];
    #    and in the mods attr here as well to access them from this runtime

    # modIndexJSON is the json file fetched from mods.factorio.com and put into the local nix store
    # modIndex is that file parsed into attrs
    inherit modIndexJSON modIndex;

    # XXX sometimes mod authors are sloppy and reupload a zip without changing
    # the version. Then, the hash needs to be deleted from
    # /var/cache/factorio-mods-hashCache.nix and hashCacheUpdater to be re-run.
    updater = hashCacheUpdater { inherit hashCache username token; releases = latestReleases; }; # the runnable bit that updates the hashCache (caches uname:token in this script)

    # This generates the next iteration of the cache from the previous one. After running this, copy the output over the old one, like so:
    #   nix-build modmanifest.nix --no-out-link --argstr version $(date +%Y.%m.%d) -A nextCache | xargs -i sudo cp {} /var/cache/factorio-mods-hashCache.nix
    # FIXME: worked before, but now new entries are `= "";` !!
    nextCache = runCommand "factorio-mods-hashCache.nix" {} ''${updater} > $out'';

    # This will be the distributed file in the channel; from that, subscribers will need to create their own set of mods:
    # (nix takes very long to eval this expression the first time, probably because it checks the sha256 on so many zips)
    latestReleasesNix = mkDefaultNix { hashCache = import nextCache; releases = latestReleases; inherit version; };

    # This generates the mod zips so they can be pushed to a cache server like so:
    #  nix-build modmanifest.nix --no-out-link --argstr version $(date +%Y.%m.%d) -A latestMods | xargs nix copy --to file:///srv/www/cache
    latestMods = callPackages latestReleasesNix {
      # username and token are used here, but not stored into any file apart from src.drvs
      inherit username token;
    };

    latestChannel = mkModsChannel { defaultNix = latestReleasesNix; inherit version binaryCacheURL; };
     
    # Now, use `let mods = pkgs.callPackage <factorio-mods> {...} in factorio-headless {mods=[mods.foobarmod-123];}` etc in your nix config
    # after setting up <factorio-mods> in the NIX_PATH to be the path to latestReleases

    # NB. final cached binary packages have hashes based on contents, so the intermediate .drv differences do not matter.
    #     This also applies to packages fetched by fetchurl: the drvs are diff if the creds are in the fetch, but final hash of the file is the same
    # XXX This takes inordinately long the first run, since it is generating and writing all the .drvs. Any way to speed it up? does MetaModsDrv have this issue?

    # WARNING username and token are cached in /nix/store/*.zip.drv files; so ensure they do not get put in the binary cache!!
  };

}
