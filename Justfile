#!/usr/bin/env just --justfile

release_repo := "maidsafe/sn-node-manager"

droplet-testbed:
  #!/usr/bin/env bash

  DROPLET_NAME="node-manager-testbed"
  REGION="lon1"
  SIZE="s-1vcpu-1gb"
  IMAGE="ubuntu-20-04-x64"
  SSH_KEY_ID="30878672"

  droplet_ip=$(doctl compute droplet list \
    --format Name,PublicIPv4 --no-header | grep "^$DROPLET_NAME " | awk '{ print $2 }')

  if [ -z "$droplet_ip" ]; then
    droplet_id=$(doctl compute droplet create $DROPLET_NAME \
      --region $REGION \
      --size $SIZE \
      --image $IMAGE \
      --ssh-keys $SSH_KEY_ID \
      --format ID \
      --no-header \
      --wait)
    if [ -z "$droplet_id" ]; then
      echo "Failed to obtain droplet ID"
      exit 1
    fi

    echo "Droplet ID: $droplet_id"
    echo "Waiting for droplet IP address..."
    droplet_ip=$(doctl compute droplet get $droplet_id --format PublicIPv4 --no-header)
    while [ -z "$droplet_ip" ]; do
      echo "Still waiting to obtain droplet IP address..."
      sleep 5
      droplet_ip=$(doctl compute droplet get $droplet_id --format PublicIPv4 --no-header)
    done
  fi
  echo "Droplet IP address: $droplet_ip"

  nc -zw1 $droplet_ip 22
  exit_code=$?
  while [ $exit_code -ne 0 ]; do
    echo "Waiting on SSH to become available..."
    sleep 5
    nc -zw1 $droplet_ip 22
    exit_code=$?
  done

  cargo build --release --target x86_64-unknown-linux-musl
  scp -r ./target/x86_64-unknown-linux-musl/release/safenode-manager \
    root@$droplet_ip:/root/safenode-manager

kill-testbed:
  #!/usr/bin/env bash

  DROPLET_NAME="node-manager-testbed"

  droplet_id=$(doctl compute droplet list \
    --format Name,ID --no-header | grep "^$DROPLET_NAME " | awk '{ print $2 }')

  if [ -z "$droplet_ip" ]; then
    echo "Deleting droplet with ID $droplet_id"
    doctl compute droplet delete $droplet_id
  fi

build-release-artifacts arch:
  #!/usr/bin/env bash
  set -e

  arch="{{arch}}"
  supported_archs=(
    "x86_64-pc-windows-msvc"
    "x86_64-apple-darwin"
    "x86_64-unknown-linux-musl"
    "arm-unknown-linux-musleabi"
    "armv7-unknown-linux-musleabihf"
    "aarch64-unknown-linux-musl"
  )

  arch_supported=false
  for supported_arch in "${supported_archs[@]}"; do
    if [[ "$arch" == "$supported_arch" ]]; then
      arch_supported=true
      break
    fi
  done

  if [[ "$arch_supported" == "false" ]]; then
    echo "$arch is not supported."
    exit 1
  fi

  if [[ "$arch" == "x86_64-unknown-linux-musl" ]]; then
    if [[ "$(grep -E '^NAME="Ubuntu"' /etc/os-release)" ]]; then
      # This is intended for use on a fresh Github Actions agent
      sudo apt update -y
      sudo apt install -y musl-tools
    fi
    rustup target add x86_64-unknown-linux-musl
  fi

  rm -rf artifacts
  mkdir artifacts
  cargo clean
  if [[ $arch == arm* || $arch == armv7* || $arch == aarch64* ]]; then
    cargo install cross
    cross build --release --target $arch --bin safenode-manager
  else
    cargo build --release --target $arch --bin safenode-manager
  fi

  find target/$arch/release -maxdepth 1 -type f -exec cp '{}' artifacts \;
  rm -f artifacts/.cargo-lock

package-release-assets version="":
  #!/usr/bin/env bash
  set -e

  architectures=(
    "x86_64-pc-windows-msvc"
    "x86_64-apple-darwin"
    "x86_64-unknown-linux-musl"
    "arm-unknown-linux-musleabi"
    "armv7-unknown-linux-musleabihf"
    "aarch64-unknown-linux-musl"
  )
  bin="safenode-manager"

  if [[ -z "{{version}}" ]]; then
    version=$(cat Cargo.toml | grep "^version" | awk -F '=' '{ print $2 }' | xargs)
  else
    version="{{version}}"
  fi

  rm -rf deploy/$bin
  find artifacts/ -name "$bin" -exec chmod +x '{}' \;
  for arch in "${architectures[@]}" ; do
    echo "Packaging for $arch..."
    if [[ $arch == *"windows"* ]]; then bin_name="${bin}.exe"; else bin_name=$bin; fi
    zip -j $bin-$version-$arch.zip artifacts/$arch/release/$bin_name
    tar -C artifacts/$arch/release -zcvf $bin-$version-$arch.tar.gz $bin_name
  done

  mkdir -p deploy/$bin
  mv *.tar.gz deploy/$bin
  mv *.zip deploy/$bin

upload-release-assets:
  #!/usr/bin/env bash
  set -e
  version=$(cat Cargo.toml | grep "^version" | awk -F '=' '{ print $2 }' | xargs)
  echo "Uploading assets to release..."
  cd deploy/safenode-manager
  ls | xargs gh release upload "v${version}" --repo {{release_repo}}

upload-release-assets-to-s3:
  #!/usr/bin/env bash
  set -e

  cd deploy/safenode-manager
  for file in *.zip *.tar.gz; do
    aws s3 cp "$file" "s3://sn-node-manager/$file" --acl public-read
  done
