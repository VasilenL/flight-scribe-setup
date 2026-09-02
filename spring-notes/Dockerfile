# ---- build (Maven + JDK 21) ----
FROM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /app
# cache dependencies first
COPY pom.xml .
RUN mvn -q -B dependency:go-offline
COPY src ./src
RUN mvn -q -B clean package -DskipTests

# ---- runtime (JRE 21) ----
FROM eclipse-temurin:21-jre
WORKDIR /app
COPY --from=build /app/target/notes-*.jar app.jar
EXPOSE 8080
# MaxRAMPercentage lets the JVM size its heap to the container memory limit.
ENTRYPOINT ["java","-XX:MaxRAMPercentage=75.0","-jar","app.jar"]
