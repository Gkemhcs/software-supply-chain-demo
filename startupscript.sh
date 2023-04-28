#!  /bin/bash
echo "WELCOME "
echo "WE ARE ABOUT TO START"
echo "ENTER YOUR PROJECT ID:-"
read PROJECT_ID
PROJECT_NUMBER=$(gcloud projects describe ${PROJECT_ID} --format "value(projectNumber)")
echo "YOUR PROJECT_ID IS ${PROJECT_ID}"
gcloud config set project ${PROJECT_ID}
gcloud services enable cloudbuild.googleapis.com binaryauthorization.googleapis.com compute.googleapis.com container.googleapis.com artifactregistry.googleapis.com clouddeploy.googleapis.com   secretmanager.googleapis.com cloudkms.googleapis.com
echo "ALL REQUIRED SERVICES ARE ENABLED"
echo "ENTER THE NAME OF YOUR CLUSTER"
read CLUSTER_NAME
echo "ENTER THE ZONE IN WHICH YOU WANT TO DEPLOY YOUR CLUSTER"
read CLUSTER_LOCATION
gcloud container clusters create $CLUSTER_NAME --zone ${CLUSTER_LOCATION} --enable-ip-alias \
--workload-pool ${PROJECT_ID}.svc.id.goog  --binauthz-evaluation-mode PROJECT_SINGLETON_POLICY_ENFORCE \
--num-nodes 1
i=1
while [[ $i == 1 ]]
do 
   status=$(gcloud container clusters describe ${CLUSTER_NAME} --zone ${CLUSTER_LOCATION} --format "value(status)")
   if [[ $status == "RUNNING" ]]
   then 
     break
   fi
done
echo "GKE CLUSTER NAMED ${CLUSTER_NAMED} IN ZONE ${CLUSTER_LOCATION} CREATED SUCCESFULLY"
echo "ENTER THE REPOSITORY NAME IN WHICH YOU WANT TO STORE YOUT IMAGE ARTIFACTS"
read REPOSITORY_NAME
echo "ENTER THE LOCATION OF YOUR REPOSITORY"
read REPOSITORY_LOCATION
echo "\n"
echo "CREATING ARTIFACT REPOSITORY"
gcloud artifacts repositories create ${REPOSITORY_NAME} --location ${REPOSITORY_LOCATION} --repository-format docker
echo "REPOSITORY SUCCESSFULLY CREATED"

echo "CREATING THE KMS KEYRINGS AND KEYS FOR ATTESTAITON "
echo "ENTER THE NAME OF KEYRING"
read KMS_KEY_RING
echo "ENTER THE LOCATION OF KEYRING"
read KMS_LOCATION
echo "ENTER THE KEY_NAME"
read KMS_KEY
gcloud kms keyrings create $KMS_KEY_RING --location $KMS_LOCATION
gcloud kms keys create $KMS_KEY --keyring $KMS_KEY_RING --location $KMS_LOCATION --purpose asymmetric-signing --default-algorithm ec-sign-p256-sha256 
# we are creating the attestor
echo "ENTER THE NOTE ID WHICH IS USED TO STORE THE METADATA OF IMAGES DURING ATTESTATIONS "
read NOTE_ID
echo "enter the description"
read NOTE_DESCRIPTION
 
sed -i s/NOTE_ID/$NOTE_ID/ note_payload.json
sed -i s/PROJECT_ID/$PROJECT_ID/ note_payload.json
sed -i s/DESCRIPTION/$NOTE_DESCRIPTION/ note_payload.json
curl -X POST \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $(gcloud auth print-access-token)"  \
    -H "x-goog-user-project: ${PROJECT_ID}" \
    --data-binary @note_payload.json  \
    "https://containeranalysis.googleapis.com/v1/projects/${PROJECT_ID}/notes/?noteId=${NOTE_ID}"
ATTESTOR_SERVICE_ACCOUNT="service-${PROJECT_NUMBER}@gcp-sa-binaryauthorization.iam.gserviceaccount.com"
sed -i s/NOTE_ID/$NOTE_ID/ iam_request.json
sed -i s/PROJECT_ID/$PROJECT_ID/  iam_request.json
sed -i s/ATTESTOR/$ATTESTOR_SERVICE_ACCOUNT/ iam_request.json
curl -X POST  \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $(gcloud auth print-access-token)" \
    -H "x-goog-user-project: ${PROJECT_ID}" \
    --data-binary @iam_request.json \
    "https://containeranalysis.googleapis.com/v1/projects/${PROJECT_ID}/notes/${NOTE_ID}:setIamPolicy"
echo "ENTER THE ATTESTOR NAME:-"
read ATTESTOR_NAME
gcloud container binauthz attestors create $ATTESTOR_NAME --attestation-authority-note $NOTE_ID \
--attestation-authority-note-project $PROJECT_ID \
echo "ATTESTOR NAMED $ATTESTOR_NAME WAS SUCCESSFULLY CREATED"
echo "ADDING THE KMS KEYS TO ATTESTOR FOR ATTESTATION SIGNING "
gcloud container binauthz attestors public-keys add --attestor $ATTESTOR_NAME \
--keyversion 1 \
--keyversion-project $PROJECT_ID \
--keyversion-keyring $KMS_KEY_RING \
--keyversion-location $KMS_LOCATION \
--keyversion-key $KMS_KEY
echo "SUCCESSFULLY ADDED PUBLIC-KEYS TO ATTESTOR"

gcloud container binauthz policy export > ba-policy.yaml
sed -i s/"evaluationMode: ALWAYS_ALLOW"/"evaluationMode: REQUIRE_ATTESTATION"/  ba-policy.yaml
echo "the policy file is opening in 5 seconds please add the require attestaions block to policy"
echo "requiresAttestationsBy:"
echo "- projects/project-name/locations/locations-name/attestors/attestor-name"
echo "KMS KEYRINGS AND KEYS AR SUCCESFULLY CREATED"


echo "CREATING REQUIRED SERVICE ACCOUNTS"

gcloud iam service-accounts create cloud-builder --display-name cloudbuilder
CLOUD_BUILDER_SA="cloud-builder@${PROJECT_ID}.iam.gserviceaccount.com"


gcloud projects add-iam-policy-binding  $PROJECT_ID \
--member "serviceAccount:${CLOUD_BUILDER_SA}" \
--role roles/name: roles/iam.serviceAccountUser
gcloud artifacts repositories add-iam-policy-binding $REPOSITORY_NAME --location $REPOSITORY_LOCATION \
--member "serviceAccount:${CLOUD_BUILDER_SA}" \
--role roles/artifactregistry.createOnPushWriter
gcloud projects add-iam-policy-binding $PROJECT_ID \
--member "serviceAccount:${CLOUD_BUILDER_SA}" \
--role roles/container.developer
gcloud projects add-iam-policy-binding $PROJECT_ID \
--member "serviceAccount:${CLOUD_BUILDER_SA}" \
--role roles/storage.admin
gcloud projects add-iam-policy-binding $PROJECT_ID \
--member "serviceAccount:${CLOUD_BUILDER_SA}" \
--role roles/logging.logWriter
gcloud deploy delivery-pipelines add-iam-policy-binding  $DELIVERY_PIPELINE_NAME --region $DELIVERY_PIPEINE_REGION \
--member "serviceAccount:${CLOUD_BUILDER_SA}" \
--roles roles/clouddeploy.releaser
gcloud projects add-iam-policy $PROJECT_ID \
--member "serviceAccount:${CLOUD_BUILDER_SA}" \
--role roles/binaryauthorization.attestorsViewer
gcloud projects add-iam-policy $PROJECT_ID \
--member "serviceAccount:${CLOUD_BUILDER_SA}" \
--role roles/cloudkms.signerVerifier
gcloud projects add-iam-policy $PROJECT_ID \
--member "serviceAccount:${CLOUD_BUILDER_SA}" \
--role roles/containeranalysis.notes.attacher
RENDER_SERVICE_ACCOUNT=render@${PROJECT_ID}.iam.gserviceaccount.com
DEPLOYER_SERVICE_ACCOUNT=deployer@${PROJECT_ID}.iam.gserviceaccount.com
gcloud iam service-accounts create render --display-name deploy-render 
gcloud iam service-accounts create deployer --display-name deploy-deployer
gcloud deploy delivery-pipelines add-iam-policy-binding $DELIVERY_PIPELINE_NAME --region DELIVERY_PIPELINE_REGION \
--member "serviceAccount:render@${PROJECT_ID}.iam.gserviceaccount.com" \
--role roles/clouddeploy.jobRunner
gcloud deploy delivery-pipelines add-iam-policy-binding $DELIVERY_PIPELINE_NAME --region DELIVERY_PIPELINE_REGION \
--member "serviceAccount:deployer@${PROJECT_ID}.iam.gserviceaccount.com" \
--role roles/clouddeploy.jobRunner
gcloud projects add-iam-policy-bonding $PROJECT_ID \
--member "serviceAccount:${DEPLOYER_SERVICE_ACCOUNT}"
--role roles/container.developer
gcloud projects add-iam-policy-bonding $PROJECT_ID \
--member "serviceAccount:${DEPLOYER_SERVICE_ACCOUNT}"
--role roles/iam.serviceAccountUser
gcloud projects add-iam-policy-bonding $PROJECT_ID \
--member "serviceAccount:${RENDER_SERVICE_ACCOUNT}"
--role roles/iam.serviceAccountUser
sed -i s/RENDER/$RENDER_SERVICE_ACCOUNT/ cloud-deploy.yaml
sed -i s/PROJECT_ID/$PROJECT_ID/ cloud-deploy.yaml
sed -i s/CLUSTER_LOCATION/$CLUSTER_LOCATION/ cloud-deploy.yaml
sed -i s/CLUSTER_NAME/$CLUSTER_NAME/ cloud-deploy.yaml
sed -i s/DEPLOYER/$DEPLOYER_SERVICE_ACCOUNT/ cloud-deploy.yaml

echo "CREATING CLOUD DEPLOY PIPELINES"
echo "ENTER THE DELIVERY PIPELINE NAME"
read DELIVERY_PIPELINE_NAME
echo "ENTER THE REGION IN WHICH YOU WANT TO CREATE A DELIVERY PIPELINE"
read DELIVERY_PIPEINE_REGION
sed -i s/"canary-pipeline"/"${DELIVERY_PIPELINE_NAME}"/ cloud-deploy.yaml
gcloud deploy apply --file cloud-deploy.yaml --region $DELIVERY_PIPEINE_REGION 
echo "DELIVERY PIPELINE NAMED ${DELIVERY_PIPELINE_NAME } CREATED SUCCESSFULLY"
echo "CREATING THE CONNECTIONS CLOUDBUILD TO GITHUB "
echo "PLEASE CREATE A AUTHORIZED TOKEN FROM YOUR GITHUB ACCOUNT AND COPY IT"
CLOUD_BUILD_SERVICE_AGENT="service-${PN}@gcp-sa-cloudbuild.iam.gserviceaccount.com"
gcloud projects add-iam-policy-binding ${PROJECT_ID} \
         --member="serviceAccount:${CLOUD_BUILD_SERVICE_AGENT}" \
         --role="roles/secretmanager.admin"
echo "ENTER YOUR GITHUB AUTHORIZED TOKEN"
read GITHUB_TOKEN
echo $GITHUB_TOKEN|gcloud secrets create git-cred --data-file -
gcloud secrets add-iam-policy-binding git-cred \
    --member="serviceAccount:${CLOUD_BUILD_SERVICE_AGENT}" \
    --role="roles/secretmanager.secretAccessor"
gcloud alpha builds connections create github connection-1 \
--region $DELIVERY_PIPELINE_REGION \
--authorizer-token-secret-version=projects/$PROJECT_ID/secrets/git-cred/versions/1
sleep 60
echo  "ENTER YOUR REPO URL"
read REPO_URL
gcloud alpha builds repositories create github repo-1 --connection connection-1 \
--region $DELIVERY_PIPELINE_REGION \
--remote-uri $REPO_URL 
echo "CREATING THE BUILD TRIGGER"
echo "ENTER THE NAME OF DOCKER IMAGE "
read IMAGE_NAME
gcloud alpha builds triggers create github \
  --name=trigger-chain \
  --repository=projects/$PROJECT_ID/locations/DELIVERY_PIPELINE_REGION/connections/connection-1/repositories/repo-1 \
  --branch-pattern=main # or --tag-pattern=TAG_PATTERN \
  --build-config=app/cloudbuild.yaml \
  --region=DELIVERY_PIPELINE_REGION
  --substitutions=_IMAGE_NAME=$IMAGE_NAME,_REPOSITORY_LOCATION=$REPOSITORY_LOCATION,_REPOSITORY_NAME=$REPOSITORY_NAME,_CLOUD_BUILD_SA=$CLOUD_BUILDER_SA,_KMS_LOCATION=$KMS_LOCATION,_KMS_KEY_RING=$KMS_KEY_RING,_KMS_KEY=$KMS_KEY,_ATTESTOR_NAME=$ATTESTOR_NAME,_DELIVERY_PIPELINE_NAME=$DELIVERY_PIPELINE_NAME,_DELIVERY_PIPEINE_REGION=$DELIVERY_PIPEINE_REGION