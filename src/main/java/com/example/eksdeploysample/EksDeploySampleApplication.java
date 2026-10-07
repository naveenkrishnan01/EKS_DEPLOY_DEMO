package com.example.eksdeploysample;

import java.net.InetAddress;
import java.util.Map;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

@SpringBootApplication
@RestController
public class EksDeploySampleApplication {

    public static void main(String[] args) {
        SpringApplication.run(EksDeploySampleApplication.class, args);
    }

    // Returns the pod name so you can see the load balancer spreading requests across replicas
    @GetMapping("/hello")
    public Map<String, String> hello() throws Exception {
        return Map.of(
                "message", "Hello from EKS updating this!!",
                "version", "v1",
                "pod", InetAddress.getLocalHost().getHostName());
    }
}
