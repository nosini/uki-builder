SBINDIR   ?= /usr/local/sbin
UNITDIR   ?= /etc/systemd/system
SYSTEMCTL ?= systemctl

.PHONY: all check install uninstall

all: check

check:
	shellcheck bin/uki-snapshots
	shellcheck -s bash tests/helpers.bash
	python3 -m py_compile bin/secureboot-keys
	bats tests/

install:
	install -D -m 0755 bin/uki-snapshots $(DESTDIR)$(SBINDIR)/uki-snapshots
	install -D -m 0755 bin/secureboot-keys $(DESTDIR)$(SBINDIR)/secureboot-keys
	install -D -m 0644 systemd/uki-snapshots.path $(DESTDIR)$(UNITDIR)/uki-snapshots.path
	install -D -m 0644 systemd/uki-snapshots.service $(DESTDIR)$(UNITDIR)/uki-snapshots.service
ifeq ($(DESTDIR),)
	$(SYSTEMCTL) daemon-reload
	$(SYSTEMCTL) enable uki-snapshots.path
	$(SYSTEMCTL) restart uki-snapshots.path
	$(SYSTEMCTL) enable uki-snapshots.service
endif

uninstall:
ifeq ($(DESTDIR),)
	-$(SYSTEMCTL) disable --now uki-snapshots.path
	-$(SYSTEMCTL) disable --now uki-snapshots.service
endif
	rm -f $(DESTDIR)$(SBINDIR)/uki-snapshots $(DESTDIR)$(SBINDIR)/secureboot-keys
	rm -f $(DESTDIR)$(UNITDIR)/uki-snapshots.path $(DESTDIR)$(UNITDIR)/uki-snapshots.service
ifeq ($(DESTDIR),)
	$(SYSTEMCTL) daemon-reload
endif
