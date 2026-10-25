PKG_NAME?=	os-mihomo
ABI?=		universal

.PHONY: package install clean

package:
	ABI="$(ABI)" PKG_NAME="$(PKG_NAME)" ./build.sh

install: package
	pkg add -f "dist/$(PKG_NAME).pkg"

clean:
	rm -rf work/freebsd-pkg
