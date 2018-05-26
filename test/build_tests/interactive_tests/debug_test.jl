using BinaryBuilder

sources = [
    "https://github.com/staticfloat/small_bin/raw/d846f4a966883e7cc032a84acf4fa36695d05482/broken_symlink/broken_symlink.tar.gz" =>
    "470d47f1e6719df286dade223605e0c7e78e2740e9f0ecbfa608997d52a00445",
]

script = """
mkdir -p a/b/c/foobar
echo "Entering $(pwd)/a/b/c/foobar, and setting FOOBAR=1"
cd a/b/c/foobar
FOOBAR=1
exit 1
"""

products(prefix) = [LibraryProduct(prefix, "libfoo", :libfoo)]
build_args = ["--verbose", "--debug", "x86_64-linux-gnu"]
build_tarballs(build_args, "Broken", sources, script, [Linux(:x86_64)], products, [])
