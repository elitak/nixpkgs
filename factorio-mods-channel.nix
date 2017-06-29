{ pkgs , ... }:
with pkgs;
with pkgs.lib;
let
  # Provide here the path to player-data.json that has your cached login authorization from the game client:
  player-data = builtins.fromJSON (builtins.readFile /home/keb/.factorio/player-data.json);
  # or you can copy-paste the values from that file directly into here thusly:
  # player-data = { service-username = "yourname"; service-token = "yourtoken"; };
  inherit (factorio-utils) defaultHashCachePath;
  binaryCacheDir = "/srv/www/cache";
  binaryCacheURL = https://cache.xor.us;
  channelPath = "${binaryCacheDir}/channels/factorio-mods";
  signingKey = /home/keb/cache.xor.us-1.key; #XXX get leaked in public store! #PRIVSTORE

  updateEverything = writeScript "update-factorio-mods-channel.sh" ''
    #!${stdenv.shell}

    nix-build()   { ${getBin nix}/bin/nix-build '<nixos>'                                           \
                                                --no-out-link                                       \
                                                --argstr version $(date +%Y.%m.%d)                  \
                                                --argstr username '${player-data.service-username}' \
                                                --argstr token '${player-data.service-token}' "$@"  \
                  ;}
    nix-channel() { ${getBin nix}/bin/nix-channel "$@"; }
    nix()         { ${getBin nix}/bin/nix "$@"; }

    set -e

    # Update the hash cache
    mkdir -p $(dirname "${defaultHashCachePath}")
    tmpCache=$(mktemp)
    $(nix-build -A factorio-utils.channel-management.updater) > $tmpCache
    mv $tmpCache "${defaultHashCachePath}"

    # Realize the mods and produce nars. This one can take a long time, until the hashes get persisted into the db.
    mods=$(nix-build -A factorio-utils.channel-management.latestMods)
    # FIXME: dont depend on nix v1.12+ ?!
    # NB need to be in nix.trustedUsers to sign!
    # XXX TODO: use xargs to avoid hitting command line limit
    nix sign-paths --key-file ${signingKey} $mods
    nix copy --to "file://${binaryCacheDir}" $mods

    # Generate channel
    mkdir -p $(dirname "${channelPath}")
    nix-build -A factorio-utils.channel-management.latestChannel --argstr binaryCacheURL '${binaryCacheURL}' -o "${channelPath}"
  '';

in
{
  services.cron = {
    enable = true;
    # TODO use unpriv-as-possible user
    # HACK here with nixos path set to home checkout temporarily
    systemCronJobs = [
      "23 04 * * * root NIX_PATH=nixos=/home/keb/nixpkgs ${updateEverything}"
      # TODO : push them and default.nix to http host
    ];
  };
}


/* TODO use a systemd timer instead of cron, something like:
 systemd.timers = flip mapAttrs' cfg.certs (cert: data: nameValuePair
        ("acme-${cert}")
        ({
          description = "Renew ACME Certificate for ${cert}";
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnCalendar = cfg.renewInterval;
            Unit = "acme-${cert}.service";
            Persistent = "yes";
            AccuracySec = "5m";
            RandomizedDelaySec = "1h";
          };
        })
      );
*/
