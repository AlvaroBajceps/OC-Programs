#!/bin/bash

echo ">> Setting up the local development environment..."
if [[ -e ".dev_env" ]]; then
  echo "  >> Removing old devenv.."
  rm -rf .dev_env
fi
mkdir -p .dev_env



echo ">> Cloning AR2000AR/opencomputers-openos-definitions..."
git clone https://github.com/AR2000AR/opencomputers-openos-definitions .dev_env/opencomputers-openos-definitions
pushd .dev_env/opencomputers-openos-definitions
echo "  >> Applying computer.getArchitecture.patch"
git apply ../../computer.getArchitecture.patch
popd

echo ">> Creating basic '.luarc.json'..."
cat << 'EOF' > .luarc.json
{
  "$schema": "https://raw.githubusercontent.com/sumneko/vscode-lua/master/setting/schema.json",
  "workspace.library": [
    ".dev_env/opencomputers-openos-definitions",
    "*/lib"
  ],
  "workspace.checkThirdParty": false
}
EOF

echo ">> Setup complete!"