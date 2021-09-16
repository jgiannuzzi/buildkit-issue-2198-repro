FROM alpine:latest

# create a layer
RUN mkdir -p /repro

# create a layer that also depends on the context
COPY repro.txt /

# create an empty layer
WORKDIR /repro
