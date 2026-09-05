# ---- Build stage ----
FROM node:26-alpine AS build
WORKDIR /app
COPY package.json ./
RUN npm install
COPY index.html vite.config.js ./
COPY src ./src
RUN npm run build

# ---- Serve stage ----
FROM nginx:1.27-alpine
# Ship as a TEMPLATE so the image's entrypoint can inject
# ${NGINX_LOCAL_RESOLVERS} (see nginx.conf.template for why).
# The filter limits envsubst to that one variable, so nginx runtime variables
# like $host and $remote_addr are left untouched.
# The image's 15-local-resolvers.envsh is OPT-IN -- it starts with
#   [ "${NGINX_ENTRYPOINT_LOCAL_RESOLVERS:-}" ] || return 0
# so without this flag NGINX_LOCAL_RESOLVERS is never exported and the template
# renders the literal string, giving:
#   [emerg] host not found in resolver "${NGINX_LOCAL_RESOLVERS}"
ENV NGINX_ENTRYPOINT_LOCAL_RESOLVERS=1
# Limit envsubst to that one variable so nginx's own $host / $remote_addr survive.
# Default suits docker-compose, where docker's embedded DNS resolves the short
# service name. Kubernetes overrides it with the FQDN (see k8s/web.yaml).
ENV API_UPSTREAM="http://api-service:5000"
ENV NGINX_ENVSUBST_FILTER="NGINX_LOCAL_RESOLVERS|API_UPSTREAM"
COPY nginx.conf.template /etc/nginx/templates/default.conf.template
COPY --from=build /app/dist /usr/share/nginx/html
EXPOSE 80
