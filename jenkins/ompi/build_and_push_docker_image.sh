#!/bin/bash -eE

# Notes:
#   Run the script under root/sudo or a user with the permissions for 'docker build'

OMPI_CI_OS_NAME=centos
OMPI_CI_OS_VERSION=7
OMPI_CI_MOFED_VERSION=4.7-1.0.0.1

# For rDMZ zone only
#OMPI_CI_DOCKER_REGISTRY_URL=rdmz-harbor.rdmz.labs.mlnx
OMPI_CI_DOCKER_REGISTRY_URL=harbor.mellanox.com
OMPI_CI_DOCKER_REGISTRY_REPO=hpcx
OMPI_CI_DOCKER_IMAGE_NAME=ompi_ci

TOP_DIR="$(git rev-parse --show-toplevel)"
TMP_DIR_DOCKER_BUILD_CONTEXT="/tmp/ompi_build_docker_image_$$"

rm -rf ${TMP_DIR_DOCKER_BUILD_CONTEXT}
mkdir -p ${TMP_DIR_DOCKER_BUILD_CONTEXT}

docker build \
  -f "${TOP_DIR}"/jenkins/ompi/Dockerfile.${OMPI_CI_OS_NAME}${OMPI_CI_OS_VERSION} \
  --no-cache \
  --network=host \
  --rm \
  --force-rm \
  --label=ompi \
  --build-arg OMPI_CI_OS_NAME=${OMPI_CI_OS_NAME} \
  --build-arg OMPI_CI_OS_VERSION=${OMPI_CI_OS_VERSION} \
  --build-arg OMPI_CI_MOFED_VERSION=${OMPI_CI_MOFED_VERSION} \
  -t ${OMPI_CI_DOCKER_REGISTRY_URL}/${OMPI_CI_DOCKER_REGISTRY_REPO}/${OMPI_CI_DOCKER_IMAGE_NAME}:latest \
  -t ${OMPI_CI_DOCKER_REGISTRY_URL}/${OMPI_CI_DOCKER_REGISTRY_REPO}/${OMPI_CI_DOCKER_IMAGE_NAME}:${OMPI_CI_OS_NAME}${OMPI_CI_OS_VERSION}_mofed${OMPI_CI_MOFED_VERSION} \
  ${TMP_DIR_DOCKER_BUILD_CONTEXT}

docker push ${OMPI_CI_DOCKER_REGISTRY_URL}/${OMPI_CI_DOCKER_REGISTRY_REPO}/${OMPI_CI_DOCKER_IMAGE_NAME}:latest
docker push ${OMPI_CI_DOCKER_REGISTRY_URL}/${OMPI_CI_DOCKER_REGISTRY_REPO}/${OMPI_CI_DOCKER_IMAGE_NAME}:${OMPI_CI_OS_NAME}${OMPI_CI_OS_VERSION}_mofed${OMPI_CI_MOFED_VERSION}

rm -rf ${TMP_DIR_DOCKER_BUILD_CONTEXT}
