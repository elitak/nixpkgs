# TODO vNext: deps. info_json.dependenices can be parsed, then info_json.name is used to lookup the deps.
# they look like a list of: "5dim_core >= 0.13.0"

# TODO use hydra + 5m interval build to pull, check, build, and host each mod in my own bincache?

# TODO how to get credentials if no token in player-data.json?
{ pkgs ? import ./. { }
, version
, username ? null
, token ? null
}:
with builtins;
with pkgs.lib;
with pkgs;
with pkgs.factorio-utils;
pkgs.factorio-utils.channel-management { inherit version username token; }
# cronned process will be:
#   nix-build to get newest upstream manifest (provide datetime as argstr to build)
#   run hashCacheUpdater
#   nix-build modmanifest.nix --argstr version `date +%Y.%m.%d` -A mods | sudo xargs nix copy --to file:///srv/www/cache
#     maybe upload to amazon and have cache.xor.us 302 redir every request
#   publish default.nix into channel (also consider just pushing to git repo)

# Some notes to be included verbatim in README:
# You can maintain your own channel this way:
# ...
# Or, simply run `nix-channel add https://factorio-mods.xor.us/channel
# In either case, to update mods, you will need to run `nix-channel --update factorio-mods` and then rebuild as appropriate, using either `nixos-rebuild switch` for the headless server or `nix-env -u factorio` for the client.
