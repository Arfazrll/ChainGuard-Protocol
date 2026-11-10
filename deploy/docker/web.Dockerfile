# syntax=docker/dockerfile:1
# A static front end (dashboard or landing page) served by nginx. From the repository root:
#   docker build -f deploy/docker/web.Dockerfile --build-arg APP=dashboard --build-arg OUT=dist/dashboard/browser .
#   docker build -f deploy/docker/web.Dockerfile --build-arg APP=landing --build-arg OUT=build .
FROM node:24-bookworm-slim AS build
ARG APP
WORKDIR /src
COPY apps/${APP}/package.json apps/${APP}/package-lock.json ./
RUN npm ci
COPY apps/${APP} ./
RUN npm run build

FROM nginx:1.27-alpine
ARG OUT
COPY --from=build /src/${OUT} /usr/share/nginx/html
COPY deploy/docker/nginx-spa.conf /etc/nginx/conf.d/default.conf
EXPOSE 80
