FROM alpine:latest

# create a layer (empty or not)
RUN echo 1

# create a layer that also depends on the context
COPY repro.txt /

# create an empty layer
RUN echo 2
