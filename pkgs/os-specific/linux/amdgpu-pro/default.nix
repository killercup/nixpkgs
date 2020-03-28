{ stdenv, fetchurl, elfutils, libelf, xz
, xorg, patchelf, openssl, libdrm, udev
, libxcb, libxshmfence, epoxy, perl, zlib
, ncurses
, libsOnly ? false, kernel ? null
}:

assert (!libsOnly) -> kernel != null;

with stdenv.lib;

let

  kernelDir = if libsOnly then null else kernel.dev;

  bitness = if stdenv.is64bit then "64" else "32";

  libArch =
    if stdenv.hostPlatform.system == "i686-linux" then
      "i386-linux-gnu"
    else if stdenv.hostPlatform.system == "x86_64-linux" then
      "x86_64-linux-gnu"
    else throw "amdgpu-pro is Linux only. Sorry. The build was stopped.";

  libReplaceDir = "/usr/lib/${libArch}";

  ncurses5 = ncurses.override { abiVersion = "5"; };

in stdenv.mkDerivation rec {

  pname = "amdgpu-pro";
  version = "20.10";
  buildnum = "1028677";
  build = "${version}-${buildnum}";

  libCompatDir = "/run/lib/${libArch}";

  amdgpuVersion = "5.4.7.33";
  amdgpuSrcDir = "amdgpu-${amdgpuVersion}-${buildnum}";

  name = pname + "-" + version + (optionalString (!libsOnly) "-${kernelDir.version}");

  src = fetchurl {
    url =
    "https://drivers.amd.com/drivers/linux/amdgpu-pro-${build}-ubuntu-18.04.tar.xz";
    sha256 = "ae2c4253bf11bea3dd01be79aeb250e4f44297ab8374e98a97716aa0809a9ed8";
    curlOpts = "--referer https://www.amd.com/en/support/kb/release-notes/rn-rad-lin-20-10-early-preview";
  };

  hardeningDisable = [ "pic" "format" ];

  inherit libsOnly;

  postUnpack = ''
    cd $sourceRoot
    mkdir root
    cd root
    for deb in ../*_all.deb ../*_i386.deb '' + optionalString stdenv.is64bit "../*_amd64.deb" + ''; do echo $deb; ar p $deb data.tar.xz | tar -xJ; done
    sourceRoot=.
  '';

  # modulePatches = optionals (!libsOnly) ([
  #   ./patches/0001-fix-warnings-for-Werror.patch
  #   ./patches/0002-drop-drm_edid_to_eld.patch
  #   ./patches/0003-disable-firmware-copy.patch
  #   ./patches/0004-device-link-hda.patch
  #   ./patches/0005-pci.patch
  # ]);

  patchPhase = optionalString (!libsOnly) ''
    pushd usr/src/${amdgpuSrcDir}
    for patch in $modulePatches
    do
      echo $patch
      patch -f -p1 < $patch || true
    done
    popd
  '';

  xreallocarray = ./xreallocarray.c;

  preBuild = optionalString (!libsOnly) ''
    pushd usr/src/${amdgpuSrcDir}
    makeFlags="$makeFlags M=$(pwd)"
    patchShebangs pre-build.sh
    ./pre-build.sh ${kernel.version}
    popd
    pushd lib
    $CC -fPIC -shared -o libhack-xreallocarray.so $xreallocarray
    strip libhack-xreallocarray.so
    popd
  '';

  modules = [
    "amd/amdgpu/amdgpu.ko"
    "amd/amdkcl/amdkcl.ko"
    "amd/amdkfd/amdkfd.ko"
    "amd/lib/amdchash.ko"
    "scheduler/amd-sched.ko"
    "ttm/amdttm.ko"
  ];

  postBuild = optionalString (!libsOnly)
    (concatMapStrings (m: "xz usr/src/${amdgpuSrcDir}/${m}\n") modules);

  NIX_CFLAGS_COMPILE = "-Werror";

  makeFlags = optionalString (!libsOnly)
    "-C ${kernel.dev}/lib/modules/${kernel.modDirVersion}/build modules";

  depLibPath = makeLibraryPath [
    stdenv.cc.cc.lib xorg.libXext xorg.libX11 xorg.libXdamage xorg.libXfixes zlib
    xorg.libXxf86vm libxcb libxshmfence epoxy openssl libdrm elfutils udev ncurses5
  ];

  installPhase = ''
    mkdir -p $out

    cp -r etc $out/etc
    cp -r lib $out/lib
    cp -r opt $out/opt

    pushd usr
    cp -r lib/${libArch}/* $out/lib
  '' + optionalString (!libsOnly) ''
    cp -r src/${amdgpuSrcDir}/firmware $out/lib/firmware
  '' + ''
    cp -r share $out/share
    popd

    pushd opt/amdgpu-pro
  '' + optionalString (!libsOnly && stdenv.is64bit) ''
    cp -r bin $out/bin
    for f in `find ../amdgpu/bin/ -type f`; do cp $f $out/bin; done
  '' + ''
    # cp -r include $out/include
    cp -r ../amdgpu/lib/${libArch}/* $out/lib
    cp -r lib/${libArch}/* $out/lib
  '' + optionalString (!libsOnly) ''
    mv lib/xorg $out/lib/xorg
    cp -r ../amdgpu/lib/xorg/* $out/lib/xorg

  '' + ''
    popd

  '' + optionalString (!libsOnly)
    (concatMapStrings (m:
      "install -Dm444 usr/src/${amdgpuSrcDir}/${m}.xz $out/lib/modules/${kernel.modDirVersion}/kernel/drivers/gpu/drm/${m}.xz\n") modules)
  + ''
    mv $out/etc/vulkan $out/share
    interpreter="$(cat $NIX_CC/nix-support/dynamic-linker)"
    libPath="$out/lib:$out/lib/gbm:$depLibPath"
  '' + optionalString (!libsOnly && stdenv.is64bit) ''
    for prog in clinfo modetest vbltest kms-universal-planes kms-steal-crtc modeprint amdgpu_test kmstest proptest wayland-scanner; do
      patchelf --interpreter "$interpreter" --set-rpath "$libPath" "$out/bin/$prog"
    done
  '' + ''
    ln -s ${makeLibraryPath [ncurses5]}/libncursesw.so.5 $out/lib/libtinfo.so.5
  '';

  # we'll just set the full rpath on everything to avoid having to track down dlopen problems
  postFixup = assert (stringLength libReplaceDir == stringLength libCompatDir); ''
    libPath="$out/lib:$out/lib/gbm:$depLibPath"
    for lib in `find "$out/lib/" -name '*.so*' -type f`; do
      patchelf --set-rpath "$libPath" "$lib"
    done
    for lib in libEGL.so.1 libGL.so.1.2 ${optionalString (!libsOnly) "xorg/modules/extensions/libglx.so"} dri/amdgpu_dri.so libamdocl12cl32.so; do
      perl -pi -e 's:${libReplaceDir}:${libCompatDir}:g' "$out/lib/$lib"
    done
    for lib in dri/amdgpu_dri.so libdrm_amdgpu.so.1.0.0 libgbm.so.1.0.0 libkms.so.1.0.0 libamdocl12cl32.so; do
      perl -pi -e 's:/opt/amdgpu-pro/:/run/amdgpu-pro/:g' "$out/lib/$lib"
    done
    substituteInPlace "$out/opt/amdgpu-pro/etc/vulkan/icd.d/amd_icd${bitness}.json" --replace "/opt/amdgpu-pro/lib/${libArch}" "$out/lib"
  '' + optionalString (!libsOnly) ''
    for lib in libglamoregl.so; do
      patchelf --add-needed $out/lib/libhack-xreallocarray.so $out/lib/xorg/modules/$lib
    done
  '';

  buildInputs = [
    libelf
    patchelf
    perl
  ];

  enableParallelBuilding = true;

  meta = with stdenv.lib; {
    description = "AMDGPU-PRO drivers";
    homepage = "https://www.amd.com/en/support/kb/release-notes/rn-rad-lin-20-10-early-preview";
    license = licenses.unfree;
    platforms = platforms.linux;
    maintainers = with maintainers; [ corngood ];
    # Copied from the nvidia default.nix to prevent a store collision.
    priority = 4;
  };
}
