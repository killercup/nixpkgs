{ stdenv, fetchFromGitHub, pkgconfig, python2Packages, makeWrapper
, fetchpatch
, bash, libsamplerate, libsndfile, readline, eigen, celt
, wafHook
# Darwin Dependencies
, aften, AudioUnit, CoreAudio, cf-private, libobjc, Accelerate

# Optional Dependencies
, dbus ? null, libffado ? null, alsaLib ? null
, libopus ? null

# Extra options
, prefix ? ""
}:

with stdenv.lib;
let
  inherit (python2Packages) python dbus-python;
  shouldUsePkg = pkg: if pkg != null && stdenv.lib.any (stdenv.lib.meta.platformMatch stdenv.hostPlatform) pkg.meta.platforms then pkg else null;

  libOnly = prefix == "lib";

  optDbus = if stdenv.isDarwin then null else shouldUsePkg dbus;
  optPythonDBus = if libOnly then null else shouldUsePkg dbus-python;
  optLibffado = if libOnly then null else shouldUsePkg libffado;
  optAlsaLib = if libOnly then null else shouldUsePkg alsaLib;
  optLibopus = shouldUsePkg libopus;
in
stdenv.mkDerivation rec {
  name = "${prefix}jack2-${version}";
  version = "1.9.12";

  src = fetchFromGitHub {
    owner = "jackaudio";
    repo = "jack2";
    rev = "v${version}";
    sha256 = "0ynpyn0l77m94b50g7ysl795nvam3ra65wx5zb46nxspgbf6wnkh";
  };

  nativeBuildInputs = [ pkgconfig python makeWrapper wafHook ];
  buildInputs = [ libsamplerate libsndfile readline eigen celt
    optDbus optPythonDBus optLibffado optAlsaLib optLibopus
  ] ++ optionals stdenv.isDarwin [
    aften AudioUnit CoreAudio Accelerate cf-private libobjc
  ];

  prePatch = ''
    substituteInPlace svnversion_regenerate.sh \
        --replace /bin/bash ${bash}/bin/bash
  '';

  patches = [ (fetchpatch {
    url = "https://github.com/jackaudio/jack2/commit/d851fada460d42508a6f82b19867f63853062583.patch";
    sha256 = "1iwwxjzvgrj7dz3s8alzlhcgmcarjcbkrgvsmy6kafw21pyyw7hp";
  }) ];

  wafConfigureFlags = [
    "--classic"
    "--autostart=${if (optDbus != null) then "dbus" else "classic"}"
  ] ++ optional (optDbus != null) "--dbus"
    ++ optional (optLibffado != null) "--firewire"
    ++ optional (optAlsaLib != null) "--alsa";

  postInstall = (if libOnly then ''
    rm -rf $out/{bin,share}
    rm -rf $out/lib/{jack,libjacknet*,libjackserver*}
  '' else ''
    wrapProgram $out/bin/jack_control --set PYTHONPATH $PYTHONPATH
  '');

  meta = {
    description = "JACK audio connection kit, version 2 with jackdbus";
    homepage = http://jackaudio.org;
    license = licenses.gpl2Plus;
    platforms = platforms.unix;
    maintainers = with maintainers; [ goibhniu ];
  };
}
