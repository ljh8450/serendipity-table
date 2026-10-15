package com.serendipity.table;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.ResponseStatus;
import org.springframework.web.bind.annotation.RestControllerAdvice;
@RestControllerAdvice
public class ApiExceptionHandler {
    public record ErrorResponse(String code, String message) {}
    @ExceptionHandler(Exception.class)
    @ResponseStatus(HttpStatus.SERVICE_UNAVAILABLE)
    public ErrorResponse unavailable(Exception exception) {
        return new ErrorResponse("SERVICE_UNAVAILABLE", "잠시 후 다시 시도해 주세요.");
    }
}
