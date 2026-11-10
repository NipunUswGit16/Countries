NODE_VERSION := $(shell cat package.json | jq -r '.engines.node' | sed -E 's/^[<>=~^v[:space:]]+//; s/[[:space:]].*//')
NVM_SH := $(if $(NVM_DIR),$(NVM_DIR)/nvm.sh,$(HOME)/.nvm/nvm.sh)

.PHONY: init
init:
	# get the correct node version from the package.json
	@if [ ! -s "$(NVM_SH)" ]; then \
	  echo "error: nvm not found at $(NVM_SH)."; \
	  echo "Install nvm, or with Node $(NODE_VERSION) active run:"; \
	  echo "  corepack enable && corepack install && pnpm install"; \
	  exit 1; \
	fi
	@echo "Installing node version $(NODE_VERSION)"
	@. "$(NVM_SH)" \
	  && nvm install "$(NODE_VERSION)" \
	  && nvm use "$(NODE_VERSION)" \
	  && echo "Enabling corepack" \
	  && corepack enable \
	  && echo "Installing dev tools" \
	  && COREPACK_ENABLE_DOWNLOAD_PROMPT=0 corepack install \
	  && echo "Installing dependencies" \
	  && pnpm install --loglevel warn \
	  && echo "Node $(NODE_VERSION) is not active in your current shell. Run:" \
	  && echo "  nvm use $(NODE_VERSION)"
