#!/bin/bash

echo -e "----- Starting deletion -----\n"

tfswitch 1.0.0

echo -e "Deleting with Terraform...\n"

cd infrastructure
terraform init -input=false -no-color
terraform destroy -input=false -auto-approve
cd ../

echo -e "Done...\n"