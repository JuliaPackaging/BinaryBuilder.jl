rm("/tmp/fake_pkgdir"; recursive=true, force=true)

# Install Ogg
BinaryBuilder.output_jll_package(
    "/tmp/fake_pkgdir/Ogg_jll",
    "Ogg_jll", 
    [LibraryProduct(Prefix("."), "libogg", :libogg)],
    true_ogg_hashes,
    [],
    true_ogg_path
)

# Install FLAC
flac_hashes = Dict(
	"aarch64-linux-gnu" => (
		"FLAC.v1.3.2.aarch64-linux-gnu.tar.gz",
		"feccdcecd2ad2d293c62cd273c33e4241c473955fd0ac2c5ccd4327414b29d2d"
	),
	"aarch64-linux-musl" => (
    	"FLAC.v1.3.2.aarch64-linux-musl.tar.gz",
		"8901e14c1615a0a94b987a45e721b6eea2bc5666130b4b7d51643fb3d45a3374"
	),
	"arm-linux-gnueabihf" => (
    	"FLAC.v1.3.2.arm-linux-gnueabihf.tar.gz",
		"2cd334d77592b245ea4359c3f15fd89877e179135c993a2c3c313546ba0a6f2b"
	),
    "arm-linux-musleabihf" => (
		"FLAC.v1.3.2.arm-linux-musleabihf.tar.gz",
		"13572624c2201860e439116f637e1754da9d1e42b3c94afa8195fbefe6bd02c7"
	),
	"i686-linux-gnu" => (
		"FLAC.v1.3.2.i686-linux-gnu.tar.gz",
		"8b9e05f832145ad29e1468780f525f45eaac4178e5fceedc9750ad20c0e954bc"
	),
    "i686-linux-musl" => (
		"FLAC.v1.3.2.i686-linux-musl.tar.gz",
		"e90ac6049cdf2b4731c3d180404c80a3360c4c786d09cf7ca689e26a8ed3b612"
	),
	"i686-w64-mingw32" => (
    	"FLAC.v1.3.2.i686-w64-mingw32.tar.gz",
		"0a6b8b8b37b8317afd1bbcbbfb69789b64fc62a0f7af91c26adf9ba7f22995b1"
	),
	"powerpc64le-linux-gnu" => (
    	"FLAC.v1.3.2.powerpc64le-linux-gnu.tar.gz",
		"5d7a7408bb6ae1e4c5761df953fd084e81634111ccce6fe06347ba6f7b522690"
	),
    "x86_64-apple-darwin14" => (
		"FLAC.v1.3.2.x86_64-apple-darwin14.tar.gz",
		"f083c99d7e2089f1fe399598061c32274e13b864ff586cbe8bfcac39bcba7576"
	),
	"x86_64-linux-gnu" => (
		"FLAC.v1.3.2.x86_64-linux-gnu.tar.gz",
		"b713fc92b13b08721f7b7c1316e4953e5be264c49bd1ebd4c886c9a2a64884f5"
	),
    "x86_64-linux-musl" => (
		"FLAC.v1.3.2.x86_64-linux-musl.tar.gz",
		"c0827a596f073e9906cd5c3ad8e76de6a57692f5d3294931a9182d83f658ed17"
	),
   	"x86_64-unknown-freebsd11.1" => (
		"FLAC.v1.3.2.x86_64-unknown-freebsd11.1.tar.gz",
		"971d1487d19c9091c3902d920504775c167543e6c4fdfcc0702ca7026a8503f5"
	),
    "x86_64-w64-mingw32" => (
		"FLAC.v1.3.2.x86_64-w64-mingw32.tar.gz",
		"8d904b2c4964d3d334ebaf948cfdddef6146f4d2955b7c8578ff6c16b99774ac"
	),
)

BinaryBuilder.output_jll_package(
    "/tmp/fake_pkgdir/FLAC_jll",
    "FLAC_jll",
    [LibraryProduct(Prefix("."), String["libFLAC"], :libflac)],
	flac_hashes,
	["Ogg_jll"],
	"https://github.com/staticfloat/FLACBuilder/releases/download/v1.3.2-2"
)
