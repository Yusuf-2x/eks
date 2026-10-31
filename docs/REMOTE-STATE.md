# Remote state (S3 bucket created by hand)

Terraform keeps a record of everything it built (the **state**). It lives in an S3 bucket so it's
safe, versioned and shareable with CI, not on your laptop.

The bucket is **created by hand, not by Terraform**. That avoids the chicken-and-egg problem
(Terraform can't store its state in a bucket it hasn't created yet), and it means
`terraform destroy` can never delete it.

| | |
|---|---|
| Bucket | `eks-project-tfstate-590184076390` (eu-west-2) |
| Cluster stack state | `eks/terraform.tfstate` (from `terraform/`) |
| ECR stack state | `ecr/terraform.tfstate` (from `terraform/ecr/`) |
| Locking | `use_lockfile = true`: Terraform writes a `.tflock` file next to the state while it runs, so two runs (you + CI) can't clash. No DynamoDB table needed. |

✅ **Already done** for this account (2026-10-31). Only repeat this for a new account.

## Create the bucket (AWS CLI, PowerShell)

```powershell
$ACCOUNT = aws sts get-caller-identity --query Account --output text
$BUCKET  = "eks-project-tfstate-$ACCOUNT"     # bucket names are global, so the account ID keeps it unique
$REGION  = "eu-west-2"

# 1. Create it (outside us-east-1 the region must be given twice)
aws s3api create-bucket --bucket $BUCKET --region $REGION --create-bucket-configuration LocationConstraint=$REGION

# 2. Versioning: every state change is kept, so a bad apply can be rolled back
aws s3api put-bucket-versioning --bucket $BUCKET --versioning-configuration Status=Enabled

# 3. Encryption at rest
aws s3api put-bucket-encryption --bucket $BUCKET --server-side-encryption-configuration '{\"Rules\":[{\"ApplyServerSideEncryptionByDefault\":{\"SSEAlgorithm\":\"AES256\"}}]}'

# 4. Never public (state files can contain secrets)
aws s3api put-public-access-block --bucket $BUCKET --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

# 5. HTTPS only
$POLICY = @"
{"Version":"2012-10-17","Statement":[{"Sid":"DenyInsecureTransport","Effect":"Deny","Principal":"*","Action":"s3:*",
 "Resource":["arn:aws:s3:::$BUCKET","arn:aws:s3:::$BUCKET/*"],"Condition":{"Bool":{"aws:SecureTransport":"false"}}}]}
"@
$POLICY | Out-File -Encoding ascii policy.json
aws s3api put-bucket-policy --bucket $BUCKET --policy file://policy.json
Remove-Item policy.json
```

Object ownership is "bucket owner enforced" (ACLs off) by default on new buckets.

**Console instead?** S3 → Create bucket → name as above, region eu-west-2, *Block all public access* ticked,
*Bucket Versioning* enabled, default encryption SSE-S3. Then add the HTTPS-only policy (step 5) under Permissions → Bucket policy.

## Check it

```powershell
aws s3api get-bucket-versioning     --bucket $BUCKET   # Status: Enabled
aws s3api get-bucket-encryption     --bucket $BUCKET   # AES256
aws s3api get-public-access-block   --bucket $BUCKET   # all four true
aws s3api get-bucket-policy         --bucket $BUCKET   # DenyInsecureTransport
```

## Point each stack at it

Each stack has a `backend.hcl.example`. Copy it to `backend.hcl` (gitignored) and put your account ID in the bucket name:

```powershell
cd terraform\ecr; copy backend.hcl.example backend.hcl; terraform init -backend-config=backend.hcl
cd ..;            copy backend.hcl.example backend.hcl; terraform init -backend-config=backend.hcl
```

## If something goes wrong

| Symptom | Fix |
|---|---|
| `Error acquiring the state lock` | A run crashed mid-way. Make sure nothing is running, then `terraform force-unlock <LOCK_ID>`. |
| State got corrupted / bad apply | The bucket is versioned: S3 console → the `.tfstate` object → *Versions* → restore the previous one. |
| `BucketAlreadyExists` | Someone else owns that name; add a suffix and use it in every `backend.hcl`. |

*(History: this bucket was first made by a small Terraform "bootstrap" stack with a DynamoDB lock table. On 2026-10-31
Terraform stopped managing it (the bucket was kept as-is), the DynamoDB table was removed, and locking moved to `use_lockfile`.)*
