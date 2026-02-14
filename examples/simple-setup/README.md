# Notes

Try a demo deployment:
```bash
cp kubeconfig.yaml ~/.kube/config
```

Deploy the example:
```bash
kubectl apply -f load_example.yaml
```

Delete the example:
```bash
kubectl delete -f load_example.yaml
```