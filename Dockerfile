FROM alpine:3.23.4@sha256:5b10f432ef3da1b8d4c7eb6c487f2f5a8f096bc91145e68878dd4a5019afde11
WORKDIR /

# iproute2 -> bridge
# bind-tools -> dig, bind
# dhclient -> get dynamic IP
# dnsmasq-dnssec -> DNS & DHCP server with DNSSEC support
# coreutils -> need REAL chown and chmod for dhclient (it uses reference option not supported in busybox)
# bash -> for scripting logic
# inotify-tools -> inotifyd for dnsmask resolv.conf reload circumvention
RUN apk add --no-cache coreutils dnsmasq-dnssec iproute2 bind-tools bash inotify-tools ip6tables

COPY config /default_config
COPY config /config
COPY bin /bin
CMD [ "/bin/entry.sh" ]

ARG IMAGE_SOURCE
#https://github.com/k8s-at-home/template-container-image
LABEL org.opencontainers.image.source $IMAGE_SOURCE
