{ pkgs, version }: pkgs.writeText "devenv-flake" ''
  {
    inputs = {
      pre-commit-hooks.url = "github:cachix/pre-commit-hooks.nix";
      pre-commit-hooks.inputs.nixpkgs.follows = "nixpkgs";
      nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
      devenv.url = "github:cachix/devenv?dir=src/modules";
    } // (if builtins.pathExists ./.devenv/flake.json 
         then builtins.fromJSON (builtins.readFile ./.devenv/flake.json)
         else {});

    outputs = { nixpkgs, ... }@inputs:
      let
        devenv = if builtins.pathExists ./.devenv/devenv.json
          then builtins.fromJSON (builtins.readFile ./.devenv/devenv.json)
          else {};
        getOverlays = inputName: inputAttrs:
          map (overlay: let
              input = inputs.''${inputName} or (throw "No such input `''${inputName}` while trying to configure overlays.");
            in input.overlays.''${overlay} or (throw "Input `''${inputName}` has no overlay called `''${overlay}`. Supported overlays: ''${nixpkgs.lib.concatStringsSep ", " (builtins.attrNames input.overlays)}"))
            inputAttrs.overlays or [];
        overlays = nixpkgs.lib.flatten (nixpkgs.lib.mapAttrsToList getOverlays (devenv.inputs or {}));
        pkgs = import nixpkgs {
          system = "${pkgs.system}";
          config = {
            allowUnfree = devenv.allowUnfree or false; 
          };
          inherit overlays;
        };
        lib = pkgs.lib;
        importModulePaths = path:
          let
            path' =
              # Fail fast ;-)
              if lib.hasPrefix "../" path
              then throw "devenv: ../ is not supported for imports"
              # Max length of path is 255?
              else if lib.hasPrefix "./" path
              then ./. + (builtins.substring 1 255 path)
              else path;
            paths = lib.splitString "/" path';
            name = builtins.head paths;
            input = inputs.''${name} or (throw "Unknown input ''${name}");
            subpath = "/''${lib.concatStringsSep "/" (builtins.tail paths)}";
            devenvPath = "''${input}" + subpath;
            pathAttrsFor = name:
              let
                path = devenvPath + "/''${name}";
                pathOrError = if builtins.pathExists path then path
                              else throw (path + " file does not exist for input ''${name}.");
                value = { inherit name path pathOrError; };
              in { inherit name value; };
            pathAttrs = builtins.listToAttrs (map pathAttrsFor [ "devenv.nix" ".devenv.flake.nix" ]);
          in pathAttrs;
        importModule = path: (importModulePaths path)."devenv.nix".pathOrError;
        project = pkgs.lib.evalModules {
          specialArgs = inputs // { inherit inputs pkgs; };
          modules = [
            (inputs.devenv.modules + /top-level.nix)
            { devenv.cliVersion = "${version}"; }
          ] ++ (map importModule (devenv.imports or [])) ++ [
            ./devenv.nix
            (devenv.devenv or {})
            (if builtins.pathExists ./devenv.local.nix then ./devenv.local.nix else {})
          ];
        };
        config = project.config;

        options = pkgs.nixosOptionsDoc {
          options = builtins.removeAttrs project.options [ "_module" ];
          # Unpack Nix types, e.g. literalExpression, mDoc.
          transformOptions =
            let isDocType = v: builtins.elem v [ "literalDocBook" "literalExpression" "literalMD" "mdDoc" ];
            in lib.attrsets.mapAttrs (_: v:
              if v ? _type && isDocType v._type then
                v.text
              else if v ? _type && v._type == "derivation" then
                v.name
              else
                v
            );
        };
      in {
        packages."${pkgs.system}" = {
          optionsJSON = options.optionsJSON;
          inherit (config) info procfileScript procfileEnv procfile;
          ci = config.ciDerivation;
        };
        devenv.containers = config.containers;
        devShell."${pkgs.system}" = config.shell;
      };
  }
''
