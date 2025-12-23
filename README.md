# pi_network_imager
# docker buildx create --use --name multi
# docker buildx inspect --bootstrap

docker buildx build \
  --platform linux/arm64 \
  -t urmelausmall/pinetworkimager:2.8 \
  --push \
  .