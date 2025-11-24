# rwx-cloud/build-push-action

GitHub Action for building OCI-compliant container images on [RWX](https://www.rwx.com/).

Building images on RWX is substantially faster and more ergonomic than building images with docker build due to techniques detailed in [this blog post](https://www.rwx.com/blog/proposal-for-a-new-way-to-build-container-images).

See more information on building OCI-compliant container images in our [documentation](https://www.rwx.com/docs/rwx/guides/build-container-images).

## Usage

### Basic Example

```yaml
name: Build Image

on:
  push:
    branches: [main]

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      - uses: rwx-cloud/build-push-action@v1
        with:
          access-token: ${{ secrets.RWX_ACCESS_TOKEN }}
          file: .rwx/build.yml
          target: app
```

### Pushing to Registries

Any docker registry supported by the [`docker/login-action`](https://github.com/docker/login-action) is also supported by RWX.
Logging in using that action will generate the necessary docker config used by the RWX CLI to push images.

Below are some common examples. See the `docker/login-action` documentation for information on how to authenticate with other registries.

#### Docker Hub

```yaml
name: Build and Push to Docker Hub

on:
  push:
    branches: [main]

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      
      - name: Login to Docker Hub
        uses: docker/login-action@v3
        with:
          username: ${{ secrets.DOCKER_USERNAME }}
          password: ${{ secrets.DOCKER_PASSWORD }}
      
      - uses: rwx-cloud/build-push-action@v1
        with:
          access-token: ${{ secrets.RWX_ACCESS_TOKEN }}
          file: .rwx/build.yml
          target: app
          push-to: docker.io/myusername/myapp:latest
```

#### AWS ECR (Elastic Container Registry)

```yaml
name: Build and Push to AWS ECR

on:
  push:
    branches: [main]

jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      id-token: write
      contents: read
    steps:
      - uses: actions/checkout@v6
      
      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::123456789012:role/github-actions-role
          aws-region: us-east-1
      
      - name: Login to ECR
        uses: docker/login-action@v3
        with:
          registry: 123456789.dkr.ecr.us-east-1.amazonaws.com
      
      - uses: rwx-cloud/build-push-action@v1
        with:
          access-token: ${{ secrets.RWX_ACCESS_TOKEN }}
          file: .rwx/build.yml
          target: app
          push-to: 123456789.dkr.ecr.us-east-1.amazonaws.com/myapp:latest
```

### Init Parameters

Init params can be passed as either comma-separated key/value pairs or as JSON.
These should match the init params in your [RWX run definition](https://www.rwx.com/docs/rwx/init-parameters).

#### Comma-separated string example

```yaml
name: Build Image with Parameters

on:
  push:
    branches: [main]

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      - uses: rwx-cloud/build-push-action@v1
        with:
          access-token: ${{ secrets.RWX_ACCESS_TOKEN }}
          file: .rwx/build.yml
          target: app
          init: 'version=1.2.3,env=production'
```

#### JSON example

```yaml
name: Build Image with JSON Parameters

on:
  push:
    branches: [main]

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      - uses: rwx-cloud/build-push-action@v1
        with:
          access-token: ${{ secrets.RWX_ACCESS_TOKEN }}
          file: .rwx/build.yml
          target: app
          init: '{"version":"1.2.3","env":"production"}'
```

### Build And Pull Simultaneously

By default, this action will not pull the built image to your local Docker daemon after building.
Use `pull: true` if you intend to use the image in additional steps within the same job.

You will also likely need to be running a Docker daemon in order to pull the image.
A minimal example is shown below.

```yaml
name: Build And Pull Image

on:
  push:
    branches: [main]

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      - name: Start Docker daemon (dind, vfs)
        run: |
          docker run -d --name dind \
            --privileged \
            -p 2375:2375 \
            -e DOCKER_TLS_CERTDIR= \
            docker:27-dind --storage-driver=vfs

          # Wait for daemon
          for i in {1..60}; do
            docker -H tcp://localhost:2375 ps > /dev/null 2>&1 && break
            sleep 1
          done

          echo "DOCKER_HOST=tcp://localhost:2375" >> $GITHUB_ENV
          echo "DOCKER_TLS_CERTDIR=" >> $GITHUB_ENV

      - uses: rwx-cloud/build-push-action@v1
        with:
          access-token: ${{ secrets.RWX_ACCESS_TOKEN }}
          file: .rwx/build.yml
          target: app
          pull: true
```

### Using Outputs

#### When Pushing to a Registry

When `push-to` is provided, `image-reference` is a Docker image reference that can be used with `docker pull`:

```yaml
name: Build, Push, and Use Image

on:
  push:
    branches: [main]

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      
      - name: Login to Docker Hub
        uses: docker/login-action@v3
        with:
          username: ${{ secrets.DOCKER_USERNAME }}
          password: ${{ secrets.DOCKER_PASSWORD }}
      
      - uses: rwx-cloud/build-push-action@v1
        id: build
        with:
          access-token: ${{ secrets.RWX_ACCESS_TOKEN }}
          file: .rwx/build.yml
          target: app
          push-to: docker.io/myusername/myapp:latest
      
      - name: Display outputs
        run: |
          echo "Image Reference: ${{ steps.build.outputs.image-reference }}"
          echo "Run URL: ${{ steps.build.outputs.run-url }}"
      
      - name: Pull and use the image
        run: |
          docker pull ${{ steps.build.outputs.image-reference }}
          docker run --rm ${{ steps.build.outputs.image-reference }} echo "Image works!"
      
      - name: Display JSON output
        run: |
          echo '${{ steps.build.outputs.json }}' | jq .
```

#### When Not Pushing to a Registry

When `push-to` is not provided, `image-reference` contains the full RWX image reference (e.g., `cloud.rwx.com/rwx:abc123...`). Use `rwx image pull` to pull the image. The RWX CLI is already installed by this action and available in subsequent steps:

```yaml
name: Build and Pull by Task ID

on:
  push:
    branches: [main]

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      
      - uses: rwx-cloud/build-push-action@v1
        id: build
        with:
          access-token: ${{ secrets.RWX_ACCESS_TOKEN }}
          file: .rwx/build.yml
          target: app
      
      - name: Display outputs
        run: |
          echo "Image Reference: ${{ steps.build.outputs.image-reference }}"
          echo "Run URL: ${{ steps.build.outputs.run-url }}"
      
      - name: Pull image using RWX CLI
        env:
          RWX_ACCESS_TOKEN: ${{ secrets.RWX_ACCESS_TOKEN }}
        run: |
          rwx image pull ${{ steps.build.outputs.image-reference }}
          # Image is now available in local Docker
          docker images | grep ${{ steps.build.outputs.image-reference }}
```

#### Sharing Outputs Across Jobs

To use outputs from this action in another job, set them as job outputs:

```yaml
name: Build and Deploy

on:
  push:
    branches: [main]

jobs:
  build:
    runs-on: ubuntu-latest
    outputs:
      image-reference: ${{ steps.build.outputs.image-reference }}
    steps:
      - uses: actions/checkout@v6
      
      - name: Login to Docker Hub
        uses: docker/login-action@v3
        with:
          username: ${{ secrets.DOCKER_USERNAME }}
          password: ${{ secrets.DOCKER_PASSWORD }}
      
      - uses: rwx-cloud/build-push-action@v1
        id: build
        with:
          access-token: ${{ secrets.RWX_ACCESS_TOKEN }}
          file: .rwx/build.yml
          target: app
          push-to: docker.io/myusername/myapp:latest

  deploy:
    needs: build
    runs-on: ubuntu-latest
    steps:
      - name: Use image from build job
        run: |
          echo "Deploying image: ${{ needs.build.outputs.image-reference }}"
          docker pull ${{ needs.build.outputs.image-reference }}
          # ... deploy using the image
```

## Inputs

| Input | Description | Required | Default |
|-------|-------------|----------|---------|
| `access-token` | RWX access token | Yes | - |
| `file` | Path to RWX config file (e.g., `.rwx/build.yml`) | Yes | - |
| `target` | Task key to build | Yes | - |
| `init` | Init parameters as JSON object or key=value pairs (comma-separated) | No | - |
| `push-to` | Registry reference to push to. Format: `registry.com/namespace/image:tag`. Requires Docker to be authenticated to the registry (e.g., via docker/login-action). | No | - |
| `pull` | Pull the built image to local Docker after building. | No | `false` |
| `cache` | Enable RWX cache. Set to `false` to disable caching. | No | `true` |
| `timeout` | Build timeout (e.g., `30m`, `1h`) | No | `30m` |

## Outputs

| Output | Description |
|--------|-------------|
| `image-reference` | Full image reference (Docker registry reference if pushed, otherwise RWX image reference) |
| `run-url` | URL to view the run in RWX Cloud |
| `json` | Complete JSON object with all details |

## Requirements

- RWX access token (set as `RWX_ACCESS_TOKEN` secret in GitHub)
- RWX config file (typically in `.rwx/` directory)
- Docker (if pushing to registries or pulling images)
- Pre-authentication with your chosen registry, using the `docker/login-action`, as described above (if you want to push the image to a registry).

## License

MIT
