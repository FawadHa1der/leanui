# The LeanUI site server. deploy/cloudflare/stage.sh fills site/ with the linux/amd64 leanui-site
# binary and the files it serves, laid out as in the repository (it serves paths relative to /app).
FROM ubuntu:24.04
WORKDIR /app
COPY site/ /app/
EXPOSE 8080
USER nobody
CMD ["/app/leanui-site", "--host", "0.0.0.0", "--port", "8080", "--dist", "dist", "--quiet"]
