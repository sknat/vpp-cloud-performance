IPsec / vpp ipsec performance
===============================

This repo contains scripts to test IPsec performance with [VPP](https://fd.io/) on various cloud providers. For now it supports AWS, Azure & GCP.
This is work in progress and mostly a personnal toolbox as of now.

Provisionning
-------------

Provisionning scripts live in `/provision`. For each provider create the corresponding `provision_[name]-conf.sh` and run `provision_[name].sh`. It shall create the schema embedded in the script.

All those script assume that you have [aws](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv1.html) [az](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli?view=azure-cli-latest) [gcloud](https://cloud.google.com/sdk/docs/downloads-versioned-archives#installation_instructions) CLIs properly installed & configured.

Running
--------

You can create a configuration file for your test setup from the `cloud-conf.sh.template` and deploy it to your instances with the `sync.sh` script. It also allows to ssh to them without typing the commands.

This copies this directory to all instances.

* `[cloud_provider_name].sh` is resonsible for setting up the configurations on the various instances
* `test.sh` is a wrapper script for running several parallel instances of `iperf3`, summing results while preserving 1-sec reports of bandwith (so sad --csv doesn't allow this). It also store results in `~/currentrun/somename`
* `orch.sh` allows to run consecutive `[cloud_provider_name].sh` and `test.sh` so that several configs are tested without human intervention.

If you want more reliable results/testing environment, check out [CSIT](https://docs.fd.io/csit/rls1908/report/)


