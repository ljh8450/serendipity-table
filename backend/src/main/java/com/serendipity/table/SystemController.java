package com.serendipity.table;

import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
public class SystemController {
    private final JdbcTemplate jdbc;
    public SystemController(JdbcTemplate jdbc) { this.jdbc = jdbc; }
    public record StatusResponse(String status) {}
    @GetMapping("/api/system/status")
    public StatusResponse status() {
        Integer marker = jdbc.queryForObject("SELECT id FROM infrastructure_marker WHERE id = 1", Integer.class);
        if (marker == null || marker != 1) throw new IllegalStateException("Infrastructure unavailable");
        return new StatusResponse("ready");
    }
}
