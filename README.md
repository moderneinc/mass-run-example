# Mass Run

This example demonstrates how to use the [Moderne CLI](https://docs.moderne.io/user-documentation/moderne-cli/getting-started/cli-intro) to run recipes on all organizations (collection of repositories) using the Moderne platform.

## Step 1: Customize the Docker image

Begin by copying the [provided Dockerfile](/Dockerfile) to your environment or cloning this entire repository.

From there, we will modify it depending on your organizational needs. Please note that the process requires access to several of your internal systems to function correctly. This includes your source control system, your artifact repository, and your Moderne tenant or DX instance.

### Self-Signed Certificates

If your internal services (artifact repository, source control, or the Moderne tenant) are accessed:

* Over HTTPS and they require [SSL/TLS](https://en.wikipedia.org/wiki/Transport_Layer_Security), but have certificates signed by a trusted-by-default root Certificate Authority.
* Over HTTP (never requiring SSL/TLS)

Please comment out the following lines from your Dockerfile:

```Dockerfile
# Configure trust store if self-signed certificates are in use for artifact repository, source control, or moderne tenant
COPY ${TRUSTED_CERTIFICATES_PATH} /usr/lib/jvm/temurin-17-jdk/lib/security/cacerts
```

If your internal services, instead, use self-signed certs, you will need to configure the CLI and JVMs installed within the Docker image to trust your organization's self-signed certificate:

When invoking, Docker, supply the `TRUSTED_CERTIFICATES_PATH` argument pointing to an appropriate [cacerts file](https://www.ibm.com/docs/en/sdk-java-technology/8?topic=certificate-cacerts-certificates-file).

If you are not sure where to get a suitable cacerts file, you can check out your local machine as you probably have one there. On JDK 8, you can find your cacerts file within its installation directory under `jre/lib/security/cacerts`. On newer JDK versions, you can find your cacerts file within is installation directory under `lib/security/cacerts`.

### Artifact repository

The CLI needs access to artifact repositories to publish the LSTs produced during the ingestion process. This is configured via the `ARTIFACTORY_DOWNLOAD_URL`, `ARTIFACTORY_UPLOAD_URL`, `ARTIFACTORY_USER`, and `ARTIFACTORY_PASSWORD` [arguments in the Dockerfile](/Dockerfile#L35-L37).

`ARTIFACTORY_DOWNLOAD_URL` should point to where the LSTs are stored.
`ARTIFACTORY_UPLOAD_URL` should point to where you want the run logs to be uploaded.

We recommend configuring a repository specifically for LSTs. This avoids intermixing LSTs with other kinds of artifacts – which has several benefits. For instance, updates and improvements to Moderne's parsers can make publishing LSTs based on the same commit desirable. However, doing so could cause problems with version number collisions if you've configured it in another way.

Keeping LSTs separate also simplifies the cleanup of old LSTs which are no longer relevant – a policy you would not wish to accidentally apply to your other artifacts.

Lastly, LSTs must be published to Maven-formatted artifact repositories, but repositories with non-JVM code likely publish artifacts to repositories of other types.

### Source Control Credentials

Most source control systems require authentication to access their repositories. If your source control **does not** require authentication to `git clone` repositories, comment out the [following lines](/Dockerfile#L35-L36):

```Dockerfile
ADD .git-credentials /root/.git-credentials
RUN git config --global credential.helper store --file=/root/.git-credentials
```

In the more common scenario that your source control does require authentication, you will need to create and include a `.git-credentials` file. You will want to supply the credentials for a service account with access to all repositories.

Each line of the `.git-credentials` file specifies the `username` and plaintext `password` for a particular `host` in the format:

```
https://username:password@host
```

For example:

```
https://sambsnyd:likescats@github.com
```

### Moderne Tenant or DX instance

Connection to a Moderne tenant allows the CLI to download LSTs and get information about your organization. The `MODERNE_TENANT` and `MODERNE_TOKEN` arguments are required to connect to a Moderne tenant.

If you are connecting to a Moderne DX instance, you will need to provide the token it was configured to accept on startup. If you are connecting to a Moderne tenant, you will need to create and use a [Moderne personal access token](https://docs.moderne.io/user-documentation/moderne-platform/how-to-guides/create-api-access-tokens).

## Step 3: Build the Docker image

Once you've customized the `Dockerfile` as needed, you can build the image with the following command, filling in your organization's specific values for the build arguments:

```bash
docker build -t moderne-mass-ingest:latest \
    --build-arg MODERNE_TENANT=<> \
    --build-arg MODERNE_TOKEN=<> \
    --build-arg TRUSTED_CERTIFICATES_PATH=<> \
    --build-arg ARTIFACTORY_DOWNLOAD_URL=<> \
    --build-arg ARTIFACTORY_UPLOAD_URL=<> \
    --build-arg ARTIFACTORY_USER=<> \
    --build-arg ARTIFACTORY_PASSWORD=<> \
    .
```

## Step 4: Deploy and run the image

Now that you have a Docker image built, you will need to deploy it to the container management platform of your choice and have it run on a schedule. We will leave this as an exercise for the reader as there are many platforms and options for running this.

<!--
## Step 5: Monitor the ingestion process

TODO: Explain how to access grafana, and where the logs are published.

## Step 6: Troubleshooting

If you want to verify that the image works as expected locally, you can spin it up with the following command:
```bash
docker run -it --rm moderne-mass-ingest:latest -p 3000:3000 -p 8080:8080 -p 9090:9090
```

In case you wish to debug the image, you can suffix the above with `bash`, and from there run `./publish.sh` to see the ingestion process in action.
-->