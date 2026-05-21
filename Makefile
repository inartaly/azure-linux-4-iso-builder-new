.PHONY: all docker-image docker-build clean

IMAGE_NAME ?= azl4-iso-builder

all: docker-build

# Build the Docker image
docker-image:
	docker build -t $(IMAGE_NAME) .

# Run the Docker container to build the ISOs
# We need --privileged because the script mounts proc/sys/dev and runs chroot
docker-build: docker-image
	@echo "Starting Docker container to build ISOs..."
	docker run --rm --privileged \
		-v "$(PWD):/workspace" \
		$(IMAGE_NAME) $(ARGS)

# Example to build just x86_64:
# make docker-build ARGS="--arch x86_64"

clean:
	@echo "Cleaning up output and build directories..."
	rm -rf output/ build/
