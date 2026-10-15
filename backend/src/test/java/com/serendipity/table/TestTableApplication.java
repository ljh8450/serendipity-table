package com.serendipity.table;

import org.springframework.boot.SpringApplication;

public class TestTableApplication {

	public static void main(String[] args) {
		SpringApplication.from(TableApplication::main).with(TestcontainersConfiguration.class).run(args);
	}

}
