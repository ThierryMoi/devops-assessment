DevOps Take-Home Assessment – Angular Todo App
Context
You are provided with a simple Angular Todo application.
Your task is to containerize it, deploy it, and automate its delivery using modern DevOps practices.
We are not looking for a step-by-step solution—we are interested in how you design and structure the deployment.

Requirements
1. Containerization
* Create a production-ready Docker image for the application
* The image should be optimized (avoid unnecessary build artifacts)
* The application must run successfully in a container

2. Kubernetes Deployment
Deploy the application on Kubernetes.
At minimum:
* The app must run as a Kubernetes workload
* It must be accessible via a Kubernetes Service
You are free to decide:
* Deployment strategy
* Number of replicas
* Exposure method (Service type / Ingress)
* Configuration approach

3. CI/CD Pipeline
Create a CI/CD pipeline using a tool of your choice (Jenkins is preferred).
The pipeline should automate:
* Build
* Container image creation
* Deployment to Kubernetes
You are expected to:
* Define the stages yourself
* Decide how secrets and credentials are handled

4. Helm (Design + Explanation)
Explain how you would improve your Kubernetes deployment using Helm.
Focus on:
* How you would structure the chart
* What you would parameterize
* Why Helm is useful in this context
(No need to fully implement unless you want to.)

5. Documentation
Provide a short report explaining:
* Your architecture and decisions
* How to build and deploy the system
* Trade-offs or assumptions you made
* What you would improve in a production environment

What We’re Evaluating
We are looking for:
* Ability to design a working deployment without rigid instructions
* Kubernetes understanding and practical judgment
* CI/CD thinking (not just syntax)
* Security awareness (even basic)
* Clarity of communication
* Production mindset

Bonus (Optional)
If you want to go further:
* Add monitoring or logging considerations
* Add rollback strategy
* Improve scalability or resilience

Important Note
There is no single correct solution.We are more interested in how you think than in a perfect implementation.

