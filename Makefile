SHELL := /bin/bash
ROOT_DIR := $(CURDIR)
DIST_DIR := $(ROOT_DIR)/dist
STAGING_DIR := $(DIST_DIR)/ecli-package
VERSION := $(shell awk '/^version:/ {print $$2; exit}' "$(ROOT_DIR)/src/bashly.yml")
ARCHIVE := $(DIST_DIR)/ecli
BASHLY := bashly
MAKESELF := makeself

.PHONY: all generate package clean

all: package

package:
	rm -rf "$(STAGING_DIR)" "$(ARCHIVE)"
	mkdir -p "$(STAGING_DIR)"
	$(BASHLY) generate
	mv "$(ROOT_DIR)/ecli" "$(STAGING_DIR)/ecli"
	chmod +x "$(STAGING_DIR)/ecli"
	cp -R "$(ROOT_DIR)/assets" "$(STAGING_DIR)/assets"
	$(MAKESELF) --noprogress "$(STAGING_DIR)" "$(ARCHIVE)" "ecli $(VERSION)" "./ecli"
	sed -i 's/^quiet="n"$$/quiet="y"/' "$(ARCHIVE)"
	chmod +x "$(ARCHIVE)"

clean:
	rm -rf "$(DIST_DIR)" "$(ROOT_DIR)/ecli"
