FROM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /workspace
COPY pom.xml ./
COPY src ./src
RUN mvn -B -DskipTests package

FROM eclipse-temurin:21.0.12_8-jre
WORKDIR /app
COPY --from=build --chown=10001:10001 /workspace/target/dlc-billing-api-0.1.0-SNAPSHOT.jar /app/billing.jar
USER 10001:10001
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "/app/billing.jar"]
