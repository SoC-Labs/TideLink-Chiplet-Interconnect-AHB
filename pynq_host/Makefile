SHELL := /bin/bash

EYE_WEB_DIR := scripts/eye_toolkit/web
SYSTEMD_USER_DIR ?= $(HOME)/.config/systemd/user
UNIT := tideeye-web.service

.PHONY: help install-web uninstall-web start-web stop-web

help:
	@echo "TideLink pynq_host targets:"
	@echo "  install-web    install $(UNIT) under $(SYSTEMD_USER_DIR)"
	@echo "  start-web      systemctl --user start tideeye-web"
	@echo "  stop-web       systemctl --user stop tideeye-web"
	@echo "  uninstall-web  remove the user unit"

install-web:
	mkdir -p "$(SYSTEMD_USER_DIR)"
	install -m 0644 "$(EYE_WEB_DIR)/systemd/$(UNIT)" "$(SYSTEMD_USER_DIR)/$(UNIT)"
	systemctl --user daemon-reload
	@echo "installed $(SYSTEMD_USER_DIR)/$(UNIT)"
	@echo "next: systemctl --user enable --now tideeye-web"

uninstall-web:
	-systemctl --user stop tideeye-web 2>/dev/null || true
	-systemctl --user disable tideeye-web 2>/dev/null || true
	rm -f "$(SYSTEMD_USER_DIR)/$(UNIT)"
	systemctl --user daemon-reload || true

start-web:
	systemctl --user start tideeye-web
	systemctl --user status tideeye-web --no-pager | head -20

stop-web:
	systemctl --user stop tideeye-web
