ARG PYTHON_MAJOR=3.11
ARG NODE_MAJOR=20

# Build the python gbstats package
FROM python:${PYTHON_MAJOR}-slim AS pybuild
WORKDIR /usr/local/src/app
COPY ./packages/stats .
RUN \
  pip3 install poetry==1.8.5 \
  && poetry install --no-root --without dev --no-interaction --no-ansi \
  && poetry build \
  && poetry export -f requirements.txt --output requirements.txt

# Build the nodejs app
FROM python:${PYTHON_MAJOR}-slim AS nodebuild
ARG NODE_MAJOR
WORKDIR /usr/local/src/app

# Set Node memory and optimization flags early
ENV NODE_OPTIONS="--max-old-space-size=8192 --optimize-for-size --gc-interval=100"
ENV NEXT_TELEMETRY_DISABLED=1

RUN apt-get update && \
    apt-get install -y wget gnupg2 build-essential && \
    echo "deb https://deb.nodesource.com/node_$NODE_MAJOR.x buster main" > /etc/apt/sources.list.d/nodesource.list && \
    wget -qO- https://deb.nodesource.com/gpgkey/nodesource.gpg.key | apt-key add - && \
    echo "deb https://dl.yarnpkg.com/debian/ stable main" > /etc/apt/sources.list.d/yarn.list && \
    wget -qO- https://dl.yarnpkg.com/debian/pubkey.gpg | apt-key add - && \
    apt-get update && \
    apt-get install -yqq nodejs=$(apt-cache show nodejs|grep Version|grep nodesource|cut -c 10-) yarn && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Copy package files
COPY package.json ./package.json
COPY yarn.lock ./yarn.lock
COPY packages/front-end/package.json ./packages/front-end/package.json
COPY packages/back-end/package.json ./packages/back-end/package.json
COPY packages/sdk-js/package.json ./packages/sdk-js/package.json
COPY packages/sdk-react/package.json ./packages/sdk-react/package.json
COPY packages/shared/package.json ./packages/shared/package.json
COPY packages/enterprise/package.json ./packages/enterprise/package.json
COPY patches ./patches

# Install dependencies with network timeout
RUN yarn install --frozen-lockfile --ignore-optional --network-timeout 100000
RUN yarn postinstall

# Copy source code
COPY packages ./packages

# Build packages separately with cleanup between steps
RUN yarn workspace @growthbook/shared build && \
    yarn workspace @growthbook/sdk-js build && \
    yarn workspace @growthbook/sdk-react build && \
    rm -rf /tmp/* && \
    yarn cache clean

RUN yarn workspace @growthbook/enterprise build && \
    rm -rf /tmp/* && \
    yarn cache clean

RUN yarn workspace @growthbook/back-end build && \
    rm -rf /tmp/* && \
    yarn cache clean

# Build front-end separately with additional memory settings
RUN cd packages/front-end && \
    NODE_OPTIONS="--max-old-space-size=8192 --optimize-for-size --gc-interval=100" \
    NEXT_MEMORY_LIMIT=8192 \
    yarn build && \
    cd ../.. && \
    rm -rf /tmp/* && \
    yarn cache clean

# Clean up and install production dependencies
RUN rm -rf node_modules \
    && rm -rf packages/back-end/node_modules \
    && rm -rf packages/front-end/node_modules \
    && rm -rf packages/front-end/.next/cache \
    && rm -rf packages/shared/node_modules \
    && rm -rf packages/enterprise/node_modules \
    && rm -rf packages/sdk-js/node_modules \
    && rm -rf packages/sdk-react/node_modules \
    && yarn install --frozen-lockfile --production=true --ignore-optional --network-timeout 100000

RUN yarn postinstall

# Package the full app together
FROM python:${PYTHON_MAJOR}-slim
ARG NODE_MAJOR
WORKDIR /usr/local/src/app

RUN apt-get update && \
    apt-get install -y wget gnupg2 && \
    echo "deb https://deb.nodesource.com/node_$NODE_MAJOR.x buster main" > /etc/apt/sources.list.d/nodesource.list && \
    wget -qO- https://deb.nodesource.com/gpgkey/nodesource.gpg.key | apt-key add - && \
    echo "deb https://dl.yarnpkg.com/debian/ stable main" > /etc/apt/sources.list.d/yarn.list && \
    wget -qO- https://dl.yarnpkg.com/debian/pubkey.gpg | apt-key add - && \
    apt-get update && \
    apt-get install -yqq nodejs=$(apt-cache show nodejs|grep Version|grep nodesource|cut -c 10-) yarn && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

COPY --from=pybuild /usr/local/src/app/requirements.txt /usr/local/src/requirements.txt
RUN pip3 install -r /usr/local/src/requirements.txt && rm -rf /root/.cache/pip

COPY --from=nodebuild /usr/local/src/app/packages ./packages
COPY --from=nodebuild /usr/local/src/app/node_modules ./node_modules
COPY --from=nodebuild /usr/local/src/app/package.json ./package.json

# Copy buildinfo if it exists
COPY buildinfo* ./buildinfo

# Maintain NODE_OPTIONS in production
ENV NODE_OPTIONS="--max-old-space-size=8192"

COPY --from=pybuild /usr/local/src/app/dist /usr/local/src/gbstats
RUN pip3 install /usr/local/src/gbstats/*.whl

# Ports
EXPOSE 3000
EXPOSE 3100

CMD ["yarn", "start"]