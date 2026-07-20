FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
ENV DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1
ENV DOTNET_CLI_TELEMETRY_OPTOUT=1
COPY Directory.Packages.props .
COPY Directory.Build.props .
COPY nuget.config .
COPY src ./src
RUN dotnet restore src/Basket.API/Basket.API.csproj
RUN dotnet publish src/Basket.API/Basket.API.csproj -c Release -o /app/publish --no-restore

FROM mcr.microsoft.com/dotnet/aspnet:10.0
WORKDIR /app
ENV ASPNETCORE_URLS=http://+:8080
ENV ASPNETCORE_ENVIRONMENT=Production
COPY --from=build /app/publish .
EXPOSE 8080
ENTRYPOINT ["dotnet", "Basket.API.dll"]
