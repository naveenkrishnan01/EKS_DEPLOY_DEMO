package com.example.eksdeploysample;

import static org.assertj.core.api.Assertions.assertThat;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.web.client.TestRestTemplate;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;

// Starts the app on a random port and checks that the endpoints the cluster depends on answer
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT)
class EksDeploySampleApplicationTests {

    @Autowired
    private TestRestTemplate rest;

    @Test
    void helloReturnsMessage() {
        ResponseEntity<String> response = rest.getForEntity("/hello", String.class);
        assertThat(response.getStatusCode()).as("/hello should return 200 OK").isEqualTo(HttpStatus.OK);
        assertThat(response.getBody()).as("/hello should return a message").contains("\"message\"");
        System.out.println("PASS: /hello returned " + response.getBody());
    }

    @Test
    void readinessProbeIsUp() {
        ResponseEntity<String> response = rest.getForEntity("/actuator/health/readiness", String.class);
        assertThat(response.getStatusCode()).as("Readiness probe should return 200 OK").isEqualTo(HttpStatus.OK);
        assertThat(response.getBody()).as("The pod should be UP").contains("UP");
        System.out.println("PASS: The pod is UP!! Readiness returned " + response.getBody());
    }
}
