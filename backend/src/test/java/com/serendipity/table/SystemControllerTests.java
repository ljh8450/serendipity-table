package com.serendipity.table;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.JdbcTemplate;
import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;
class SystemControllerTests {
    @Test void readyRequiresDatabaseMarker() {
        JdbcTemplate jdbc = mock(JdbcTemplate.class);
        when(jdbc.queryForObject("SELECT id FROM infrastructure_marker WHERE id = 1", Integer.class)).thenReturn(1);
        assertEquals("ready", new SystemController(jdbc).status().status());
    }
    @Test void databaseErrorsDoNotLeakIntoResponse() {
        var body = new ApiExceptionHandler().unavailable(new RuntimeException("sensitive connection details"));
        assertEquals("SERVICE_UNAVAILABLE", body.code());
        assertFalse(body.message().contains("sensitive"));
    }
}
