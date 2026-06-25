#include <fmt/core.h>
#include <json/json.h>

#include <sstream>

int main() {
  Json::Value root;
  root["greeting"] = "Hello World!";
  root["count"] = 3;

  Json::StreamWriterBuilder writer;
  writer["indentation"] = "  ";
  const std::string serialized = Json::writeString(writer, root);

  Json::CharReaderBuilder reader;
  Json::Value parsed;
  std::string errors;
  std::istringstream is(serialized);
  if (!Json::parseFromStream(reader, is, &parsed, &errors)) {
    fmt::print("failed to parse json: {}\n", errors);
    return 1;
  }

  fmt::print("{} (x{})\n",
             parsed["greeting"].asString(),
             parsed["count"].asInt());
  return 0;
}
