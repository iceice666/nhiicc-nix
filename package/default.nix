{
  lib,
  stdenvNoCC,
  fetchurl,
  autoPatchelfHook,
  unzip,
  pcsclite,
  openssl,
  coreutils,
  writeShellApplication,
  callPackage,
  systemd,
  util-linux,
  procps,
  iproute2,
  ccid,
  runCommand,
  python3,
  stdenv,
}:

let
  version = "20240710.1";
  srcs = {
    x86_64-linux = fetchurl {
      name = "CMS_mNHIICC_Setup-${version}.Linux.zip";
      url = "https://cloudicweb.nhi.gov.tw/cloudic/system/SMC/CMS_mNHIICC_Setup.Linux.zip";
      hash = "sha256-+zRz/RoajGXAly2KOVcKvbu1N8wyysXExRUnscH84ZY=";
    };
  };

  certificateHelper = writeShellApplication {
    name = "nhiicc-init-certificate";
    runtimeInputs = [
      openssl
      coreutils
    ];
    text = builtins.readFile ./init-certificate.sh;
  };
  endpointHelper = writeShellApplication {
    name = "nhiicc-resolve-endpoint";
    text = ''
      exec ${python3}/bin/python3 ${./resolve-endpoint.py} "$@"
    '';
  };

  tlsHelper = writeShellApplication {
    name = "nhiicc-check-tls";
    text = ''
      exec ${python3}/bin/python3 ${./check-tls.py} "$@"
    '';
  };

  session = writeShellApplication {
    name = "nhiicc-session";
    runtimeInputs = [
      coreutils
      openssl
      util-linux
      procps
      iproute2
    ];
    text = ''
      root="$(dirname "$(dirname "$(readlink -f "$0")")")"
      certificate_tool=${certificateHelper}/bin/nhiicc-init-certificate
      tls_tool=${tlsHelper}/bin/nhiicc-check-tls
      pcscd=${pcsclite}/bin/pcscd
      assets="$root/share/nhiicc"
      vendor="$root/bin/mLNHIICC"
      vendor_path=${lib.makeBinPath [ coreutils ]}
      export PCSCLITE_HP_DROPDIR=${ccid}/pcsc/drivers
    ''
    + builtins.readFile ./session.sh;
  };

  launcher = writeShellApplication {
    name = "nhiicc";
    runtimeInputs = [
      coreutils
      procps
      iproute2
    ];
    text = ''
      root="$(dirname "$(dirname "$(readlink -f "$0")")")"
      systemd_run=${systemd}/bin/systemd-run
      endpoint_tool=${endpointHelper}/bin/nhiicc-resolve-endpoint
      supervisor="$root/bin/nhiicc-session"
    ''
    + builtins.readFile ./launch.sh;
  };
in
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "nhiicc";
  inherit version;
  src =
    srcs.${stdenvNoCC.hostPlatform.system}
      or (throw "nhiicc: unsupported platform ${stdenvNoCC.hostPlatform.system}");

  nativeBuildInputs = [
    autoPatchelfHook
    unzip
    python3
  ];
  buildInputs = [ pcsclite ];

  unpackPhase = ''
    runHook preUnpack
    unzip "$src"
    tar -xf mLNHIICC_Setup.${version}.tar.xz
    cd mLNHIICC_Setup
    runHook postUnpack
  '';

  postPatch = ''
    python3 ${./patch-binary.py} x64/mLNHIICC
  '';

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    install -Dm755 x64/mLNHIICC "$out/bin/mLNHIICC"
    patchelf --remove-rpath "$out/bin/mLNHIICC"
    mkdir -p "$out/share/nhiicc"
    cp -r html web "$out/share/nhiicc/"
    ln -s ${certificateHelper}/bin/nhiicc-init-certificate "$out/bin/nhiicc-init-certificate"
    install -m755 ${launcher}/bin/nhiicc "$out/bin/nhiicc"
    install -m755 ${session}/bin/nhiicc-session "$out/bin/nhiicc-session"

    runHook postInstall
  '';

  passthru.tests = {
    endpoint =
      runCommand "nhiicc-endpoint-tests"
        {
          nativeBuildInputs = [ python3 ];
          ENDPOINT_SOURCE = ./resolve-endpoint.py;
          LAUNCH_SOURCE = ./launch.sh;
        }
        ''
          python3 ${./test-endpoint.py}
          touch "$out"
        '';
    tls =
      runCommand "nhiicc-tls-tests"
        {
          nativeBuildInputs = [
            python3
            certificateHelper
          ];
          TLS_SOURCE = ./check-tls.py;
        }
        ''
          python3 ${./test-tls.py}
          touch "$out"
        '';
    startup =
      runCommand "nhiicc-startup-tests"
        {
          nativeBuildInputs = [
            stdenv.cc
            coreutils
          ];
        }
        ''
          $CC -shared -fPIC -Wall -Wextra -Werror ${./test-startup.c} -ldl -o startup.so
          # Interpose before service initialization: no sockets, USB or threads.
          timeout 5 env LD_PRELOAD="$PWD/startup.so" ${finalAttrs.finalPackage}/bin/mLNHIICC
          touch "$out"
        '';
    certificates = callPackage ./tests.nix { inherit certificateHelper; };
    session =
      runCommand "nhiicc-session-tests"
        {
          nativeBuildInputs = [
            python3
            coreutils
          ];
          SESSION_SOURCE = ./session.sh;
        }
        ''
          python3 ${./test-session.py}
          touch "$out"
        '';
  };

  meta = {
    description = "Taiwan National Health Insurance card web authentication middleware";
    homepage = "https://cloudicweb.nhi.gov.tw/cloudic/system/SMC/mEventesting.htm";
    license = lib.licenses.unfree;
    mainProgram = "nhiicc";
    platforms = builtins.attrNames srcs;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
})
