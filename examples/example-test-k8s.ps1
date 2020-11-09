.\provision.ps1 `
  -Namespace test `
  -Name k8s-app `
  -VMSpecFile .\recipes\microk8s\app\vmspec.json `
  -CloudInitFile .\recipes\microk8s\app\cloud-init.yml
