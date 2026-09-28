SBINDIR   ?= /usr/local/sbin
UNITDIR   ?= /etc/systemd/system
SYSTEMCTL ?= systemctl

.PHONY: all check install uninstall

all: check

check:
	shellcheck bin/uki-snapshots

install:
	install -D -m 0755 bin/uki-snapshots $(DESTDIR)$(SBINDIR)/uki-snapshots
	install -D -m 0644 systemd/uki-snapshots.path $(DESTDIR)$(UNITDIR)/uki-snapshots.path
	install -D -m 0644 systemd/uki-snapshots.service $(DESTDIR)$(UNITDIR)/uki-snapshots.service
ifeq ($(DESTDIR),)
	$(SYSTEMCTL) daemon-reload
	$(SYSTEMCTL) enable --now uki-snapshots.path
endif

uninstall:
ifeq ($(DESTDIR),)
	-$(SYSTEMCTL) disable --now uki-snapshots.path
	-$(SYSTEMCTL) stop uki-snapshots.service
endif
	rm -f $(DESTDIR)$(SBINDIR)/uki-snapshots
	rm -f $(DESTDIR)$(UNITDIR)/uki-snapshots.path $(DESTDIR)$(UNITDIR)/uki-snapshots.service
ifeq ($(DESTDIR),)
	$(SYSTEMCTL) daemon-reload
endif
