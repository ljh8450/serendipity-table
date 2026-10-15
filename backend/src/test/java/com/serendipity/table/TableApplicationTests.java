package com.serendipity.table;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import org.junit.jupiter.api.Tag;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.web.server.LocalServerPort;
import org.springframework.context.annotation.Import;
import org.springframework.jdbc.core.JdbcTemplate;
import org.flywaydb.core.Flyway;
import org.springframework.boot.webmvc.test.autoconfigure.AutoConfigureMockMvc;
import org.springframework.test.web.servlet.MockMvc;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.user;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;
import static org.junit.jupiter.api.Assertions.*;

@Tag("integration")
@AutoConfigureMockMvc
@Import(TestcontainersConfiguration.class)
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT, properties = "app.allowed-origins=http://localhost:5173")
class TableApplicationTests {
    @LocalServerPort int port;
    @Autowired JdbcTemplate jdbc;
    @Autowired Flyway flyway;
    @Autowired MockMvc mvc;
    private HttpResponse<String> request(String path, String origin, boolean post) throws Exception {
        var builder = HttpRequest.newBuilder(URI.create("http://localhost:" + port + path));
        if (origin != null) builder.header("Origin", origin);
        if (post) builder.POST(HttpRequest.BodyPublishers.noBody());
        return HttpClient.newHttpClient().send(builder.build(), HttpResponse.BodyHandlers.ofString());
    }
    @Test void databaseAndMigrationAreReadyAndRepeatable() throws Exception {
        assertEquals(1, jdbc.queryForObject("SELECT count(*) FROM infrastructure_marker", Integer.class));
        assertEquals(0, flyway.migrate().migrationsExecuted);
        var response = request("/api/system/status", "http://localhost:5173", false);
        assertEquals(200, response.statusCode());
        assertTrue(response.body().contains("ready"));
        assertEquals("http://localhost:5173", response.headers().firstValue("Access-Control-Allow-Origin").orElseThrow());
    }
    @Test void rejectsUnknownOriginAndAnonymousProtectedApi() throws Exception {
        assertEquals(403, request("/api/system/status", "https://unknown.example", false).statusCode());
        assertEquals(401, request("/api/private", null, false).statusCode());
        assertEquals(401, request("/api/private", null, true).statusCode());
        mvc.perform(post("/api/private").with(user("test-only"))).andExpect(status().isForbidden());
    }
}
