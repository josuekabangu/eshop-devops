FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
ENV DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1
ENV DOTNET_CLI_TELEMETRY_OPTOUT=1
COPY eShop/Directory.Packages.props .
COPY eShop/Directory.Build.props .
COPY eShop/nuget.config .
COPY eShop/src ./src
RUN dotnet restore src/WebhookClient/WebhookClient.csproj
RUN dotnet publish src/WebhookClient/WebhookClient.csproj -c Release -o /app/publish --no-restore

FROM mcr.microsoft.com/dotnet/aspnet:10.0
WORKDIR /app
ENV ASPNETCORE_URLS=http://+:8080
COPY --from=build /app/publish .
EXPOSE 8080
ENTRYPOINT ["dotnet", "WebhookClient.dll"]
