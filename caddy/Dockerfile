FROM golang:1.25-alpine AS builder

RUN apk add --no-cache git
RUN go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest

WORKDIR /src
RUN xcaddy build --output /bin/caddy --with github.com/caddy-dns/cloudflare

FROM caddy:2.10.2-alpine
COPY --from=builder /bin/caddy /usr/bin/caddy
