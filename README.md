# Auto-scaling Gitlab Runner in GCE

Few days ago I wanted to give the [Gitlab CI](https://about.gitlab.com/gitlab-ci/) a spin and came up with this solution to use
GCE as a scaling cluster for running the tests for different backend projects.
As the workers in this setup uses Docker, I can define in my projects CI configuration what kind of image I want to run my test on,
wether it is Node.JS, Python, etc. This is really great, as then I do not have to configure servers for each of the different
environments separetly and scale those.

This repo contains a simple example setup of setting up an auto-scaling [Gitlab Runner](https://gitlab.com/gitlab-org/gitlab-ci-multi-runner) inside GCE.
We will setup a Runner using "docker+machine" -executor that runs in very minimalistic idle costs (~ $20USD/month).
We will also try to use Google Cloud Storage as the Runners cache.

## Preparations

First of all, you should have a Google Cloud -project setup with billing and Compute Engine enabled.
You should also have the Google Cloud SDK installed.
And of course, you need a running Gitlab instance.

Once you have the Project ID, you can set following configs in the terminal where you will be executing the
gcloud-commands. You can set the Region and zone to what ever you prefer.

```sh
export PROJECT_ID=YOUR-PROJECT_ID
gcloud config set project $PROJECT_ID
gcloud config set compute/region europe-west1
gcloud config set compute/zone europe-west1-c
```

Next take note of your Gitlab instances Runner Registration token. This can be found from the Admin Area -> Overview -> Runners.
export it to the environment:

```sh
export RUNNER_REGISTER_TOKEN=YOUR-GITLAB-RUNNER-REGISTRATION_TOKEN
```

Now create yourself a Google Cloud Storage (GCS) Buckets for holding your Config templates and the Cache.
You can do this from your Google Cloud Console or by running following commands:

```sh
export CONFIG_BUCKET=YOUR-GCS-CONFIG_BUCKET_NAME

gsutil mb -l europe-west1 gs://YOUR-GCS-CACHE_BUCKET_NAME
gsutil mb -l europe-west1 gs://$CONFIG_BUCKET
```

You just need to make a note about those bucket names, as we need them later during this setup.
The inside the Google Cloud Consoles Storage -section, go to Settings -> Interoperability, and create
an Interoperable storage access key.

Next lets prepare the configs/shared-as.toml -file (Gitlab Runner config template) with our bucket and Gitlab information:
the Gitlab CI uri should be in format https://gitlab.domain.tld/ci

```sh
export GITLAB_CI_URI=insert-your-gitlab_full_uri-here

sed -i '' -e 's,GITLAB_CI_URI,'$GITLAB_CI_URI',' configs/shared-as.toml
sed -i '' -e 's/YOUR-GCS-CACHE_BUCKET_NAME/insert-your-cache_bucket_name-here/' configs/shared-as.toml
sed -i '' -e 's/YOUR-GCS-ACCESS_KEY/insert-your-access_key-here/' configs/shared-as.toml
sed -i '' -e 's/YOUR-GCS-SECRET_KEY/insert-your-secret_key-here/' configs/shared-as.toml
```

Then lets copy this config file to our GCS:

```sh
gsutil cp -r configs/* gs://YOUR-GCS-CONFIG_BUCKET_NAME/
```

Now we are ready to start deploying our setup.

First of all we will need to create a NAT gateway, so we do not need to expose our worker nodes to the public internet.
Here is the simplest way, I've found (and used quite a lot) to build a simple NAT gateway using the legacy network (without subnetworks).
This practice has been taken from here (https://cloud.google.com/compute/docs/networking#natgateway)

```sh
gcloud compute instances create "project-nat" \
--project=$PROJECT_ID \
--description="NATs outgoing internet for nodes" \
--machine-type "f1-micro" --can-ip-forward \
--image "/debian-cloud/debian-8-jessie-v20160803" \
--tags "project-nat" --metadata-from-file "startup-script=startup-scripts/configure-nat-gw.sh"

gcloud compute routes create "no-ip-internet-route" \
--project=$PROJECT_ID \
--destination-range "0.0.0.0/0" \
--next-hop-instance-zone europe-west1-c --next-hop-instance=project-nat --tags "project-noip","docker-machine" --priority 200
```

Now that we have a NAT gateway to forward all outgoing traffic from nodes that have tag "project-noip" or "docker-machine" to external network, we can setup the Auto-scaling cluster.

Lets also setup a firewall rules for allowing incoming HTTP and HTTPS communication towards nodes that have related tags.
It might be that your project already have these setup (in that case, you can just skip this step)

```sh
gcloud compute firewall-rules create allow-http --project $PROJECT_ID \
--target-tags http-server --allow tcp:tcp80

gcloud compute firewall-rules create allow-https --project $PROJECT_ID \
--target-tags https-server --allow tcp:443
```

This is the last command you need to run, everything else from this point forward will be automated.

```sh
gcloud --project $PROJECT_ID compute instances create "gitlab-ci-runner-as-1" \
--machine-type "g1-small" --network "default" --maintenance-policy "MIGRATE" \
--scopes default="https://www.googleapis.com/auth/devstorage.read_write","https://www.googleapis.com/auth/logging.write","https://www.googleapis.com/auth/monitoring.write","https://www.googleapis.com/auth/servicecontrol","https://www.googleapis.com/auth/service.management.readonly","https://www.googleapis.com/auth/compute" \
--tags "http-server","https-server","gitlab-runner" \
--image "/debian-cloud/debian-8-jessie-v20160803" \
--boot-disk-size "10" --boot-disk-type "pd-standard" --boot-disk-device-name "gitlab-ci-runner-as-1" \
--metadata register_token=$RUNNER_REGISTER_TOKEN,config_bucket=$CONFIG_BUCKET,runner_name=gitlab-ci-runner-as-1,gitlab_uri=$GITLAB_CI_URI,runner_tags=backend \
--metadata-from-file "startup-script=startup-scripts/prepare-runner.sh"
```

And thats it, this process will take some time, so go ahead and grap a cup of coffee and you can check in your Gitlab Runners page,
when the cluster is ready.
Also you can of course monitor the progress manually by SSH:ing to the Runner controller machine and tailing the /var/log/syslog

```sh
gcloud --project $PROJECT_ID compute ssh gitlab-ci-runner-as-1
```

## Unresolved

I still haven't found out why the Cache is not working properly, it might be the way the
Gitlab Runner currently handles Google Cloud Storage endpoint with the S3 compatibility mode.
I'll try to find time to fork the runner repository and rewrite the minion cache client to use the latest information
of how the GCS wants to handle the interoperability communication.
