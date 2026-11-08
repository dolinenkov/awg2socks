# AWG ingress image: amneziawg-go + awg (setconf tool) + tun2socks in ONE container.
# Pin the refs below to versions you have tested; the defaults are placeholders.

ARG ALPINE_VERSION=3.22
ARG GO_IMAGE=golang:1.25-alpine

# ---- Go binaries: amneziawg-go, tun2socks ---------------------------------
FROM ${GO_IMAGE} AS go-build
RUN apk add --no-cache git
ARG AWG_GO_REF=v3.1.20260828    # PIN: tag of amnezia-vpn/amneziawg-go (go.mod needs Go >= 1.25)
ARG T2S_VERSION=v2.6.0          # PIN: check xjasonlyu/tun2socks releases
ENV CGO_ENABLED=0 GOBIN=/out GOTOOLCHAIN=auto
RUN git clone https://github.com/amnezia-vpn/amneziawg-go /src/awg-go \
 && cd /src/awg-go && git checkout "${AWG_GO_REF}" \
 && go build -trimpath -ldflags "-s -w" -o /out/amneziawg-go .
RUN go install -trimpath -ldflags "-s -w" github.com/xjasonlyu/tun2socks/v2@${T2S_VERSION}

# ---- C tool: awg (used only for `awg setconf`) ------------------------------
FROM alpine:${ALPINE_VERSION} AS tools-build
RUN apk add --no-cache build-base git linux-headers
ARG AWG_TOOLS_REF=v3.1.20260812 # PIN: tag of amnezia-vpn/amneziawg-tools
RUN git clone https://github.com/amnezia-vpn/amneziawg-tools /src/tools \
 && cd /src/tools && git checkout "${AWG_TOOLS_REF}" \
 && make -C src

# ---- Final image ------------------------------------------------------------
FROM alpine:${ALPINE_VERSION}
RUN apk add --no-cache bash iproute2 iptables tini
COPY --from=go-build    /out/amneziawg-go /out/tun2socks /usr/local/bin/
# `make` builds src/wg; only `make install` renames it to awg
COPY --from=tools-build /src/tools/src/wg /usr/local/bin/awg
COPY --chmod=0755 entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/sbin/tini", "--", "/entrypoint.sh"]
