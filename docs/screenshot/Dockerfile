FROM alpine:3.22
RUN apk add --no-cache bash jq git python3 chromium fontconfig curl xz font-dejavu font-noto-common \
 && mkdir -p /usr/share/fonts/nerd \
 && curl -fsSL https://github.com/ryanoasis/nerd-fonts/releases/download/v3.5.1/JetBrainsMono.tar.xz \
    | tar -xJ -C /usr/share/fonts/nerd \
 && fc-cache -f
