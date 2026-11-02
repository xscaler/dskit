#!/usr/bin/env bash
# Install a pinned tool release into /usr/local/bin after verifying its sha256.
#
# usage: xs-install-tool.sh <crane|cosign|syft|trivy|gotestsum|shellcheck>
set -euo pipefail

tool="${1:?tool name required}"

case "$(uname -m)" in
  x86_64) arch=amd64 ;;
  aarch64 | arm64) arch=arm64 ;;
  *)
    echo "::error::unsupported machine $(uname -m)"
    exit 1
    ;;
esac

# Per tool: download url, sha256, kind (tar|bin), path of the binary inside the archive.
case "${tool}-${arch}" in
  crane-amd64)
    url=https://github.com/google/go-containerregistry/releases/download/v0.22.1/go-containerregistry_Linux_x86_64.tar.gz
    sum=0ab7a1d6932a213aed964ce97666c3077fe691c8606413674a8b3e0b9ec4cda0 kind=tar member=crane ;;
  crane-arm64)
    url=https://github.com/google/go-containerregistry/releases/download/v0.22.1/go-containerregistry_Linux_arm64.tar.gz
    sum=898c0cff975f898a33e8c4580bdafb0e7c02c7faa33374e946762f97c4ab7110 kind=tar member=crane ;;
  cosign-amd64)
    url=https://github.com/sigstore/cosign/releases/download/v3.1.4/cosign-linux-amd64
    sum=424e2c97d0b45fd7a6b608a87f090f35633f4c23ece5f092d48bba11aaf4bbfa kind=bin member=cosign ;;
  cosign-arm64)
    url=https://github.com/sigstore/cosign/releases/download/v3.1.4/cosign-linux-arm64
    sum=ade83b7aac62e131cacfe96d958948b2150cc9efec46a570a2649b8e27dedad2 kind=bin member=cosign ;;
  syft-amd64)
    url=https://github.com/anchore/syft/releases/download/v1.55.0/syft_1.55.0_linux_amd64.tar.gz
    sum=bb65249542db5fedeeb4d3f9b018b75e7264dbfbbb10486f044581a92f90490d kind=tar member=syft ;;
  syft-arm64)
    url=https://github.com/anchore/syft/releases/download/v1.55.0/syft_1.55.0_linux_arm64.tar.gz
    sum=929bd163db2d7cd2255d3bcb8967208079813d7b46b0c952f7b794d8e2c7d304 kind=tar member=syft ;;
  trivy-amd64)
    url=https://github.com/aquasecurity/trivy/releases/download/v0.76.1/trivy_0.76.1_Linux-64bit.tar.gz
    sum=c7cbe3137fb8a48a17574bede3dd6beb16742d1e9772929940fc90082c39d9c0 kind=tar member=trivy ;;
  trivy-arm64)
    url=https://github.com/aquasecurity/trivy/releases/download/v0.76.1/trivy_0.76.1_Linux-ARM64.tar.gz
    sum=e174dff2a6dba5e3ae41f8d0537a6324405bd08132497340304c6b20e0f16a1f kind=tar member=trivy ;;
  gotestsum-amd64)
    url=https://github.com/gotestyourself/gotestsum/releases/download/v1.9.0/gotestsum_1.9.0_linux_amd64.tar.gz
    sum=0a0a310d6331447559b836407bcb4b98e758b9d4d3d829f3505f55ec74b26cae kind=tar member=gotestsum ;;
  gotestsum-arm64)
    url=https://github.com/gotestyourself/gotestsum/releases/download/v1.9.0/gotestsum_1.9.0_linux_arm64.tar.gz
    sum=9c8da1d4f4118da436705f2365cfd99c4f516cd1c91b19acc03a1cd47efb382f kind=tar member=gotestsum ;;
  shellcheck-amd64)
    url=https://github.com/koalaman/shellcheck/releases/download/v0.9.0/shellcheck-v0.9.0.linux.x86_64.tar.xz
    sum=700324c6dd0ebea0117591c6cc9d7350d9c7c5c287acbad7630fa17b1d4d9e2f kind=tarxz member=shellcheck-v0.9.0/shellcheck ;;
  shellcheck-arm64)
    url=https://github.com/koalaman/shellcheck/releases/download/v0.9.0/shellcheck-v0.9.0.linux.aarch64.tar.xz
    sum=179c579ef3481317d130adebede74a34dbbc2df961a70916dd4039ebf0735fae kind=tarxz member=shellcheck-v0.9.0/shellcheck ;;
  *)
    echo "::error::no pinned release for ${tool} on ${arch}"
    exit 1
    ;;
esac

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
curl -fsSL --retry 3 -o "${tmp}/download" "${url}"
echo "${sum}  ${tmp}/download" | sha256sum -c -

case "${kind}" in
  tar) tar -xzf "${tmp}/download" -C "${tmp}" "${member}" ;;
  tarxz) tar -xJf "${tmp}/download" -C "${tmp}" "${member}" ;;
  bin) mv "${tmp}/download" "${tmp}/${member}" ;;
  *)
    echo "::error::unknown archive kind ${kind}"
    exit 1
    ;;
esac

sudo=""
if [[ "$(id -u)" != "0" ]]; then sudo="sudo"; fi
${sudo} install -m 0755 "${tmp}/${member}" "/usr/local/bin/${tool}"
case "${tool}" in
  crane | cosign) version_cmd=version ;;
  *) version_cmd=--version ;;
esac
installed="$("${tool}" "${version_cmd}" 2>&1)"
echo "${installed}" | sed -n '1p'
