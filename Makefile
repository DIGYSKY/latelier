.PHONY: build test app run dmg release install cert icon clean

build:
	swift build

test:
	scripts/test.sh

app:
	scripts/build-app.sh

run: app
	open "build/L’Atelier.app"

# .dmg ; avec SIGN_IDENTITY et NOTARY_PROFILE : signé et notarisé (voir scripts/release.sh).
dmg:
	scripts/release.sh

# Publie VERSION sur GitHub (tag, .dmg, .sha256) : voir scripts/publish-release.sh.
release:
	scripts/publish-release.sh

# Compile et installe dans /Applications (l’ancienne version va à la corbeille).
install:
	./install.sh

# Certificat de signature auto-signé (une fois) : identité stable d’une version à l’autre.
cert:
	scripts/make-signing-cert.sh

# Régénère Support/AppIcon.icns.
icon:
	mkdir -p build/AppIcon.iconset
	swift scripts/make-icon.swift build/icon.png
	for s in 16 32 128 256 512; do \
		sips -z $$s $$s build/icon.png --out build/AppIcon.iconset/icon_$${s}x$${s}.png >/dev/null; \
		sips -z $$((s*2)) $$((s*2)) build/icon.png --out build/AppIcon.iconset/icon_$${s}x$${s}@2x.png >/dev/null; \
	done
	iconutil -c icns build/AppIcon.iconset -o Support/AppIcon.icns

clean:
	rm -rf .build build
