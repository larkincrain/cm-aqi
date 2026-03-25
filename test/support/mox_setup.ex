# This file sets up Mox — a library for defining mock modules in tests.
#
# ## What is Mox?
#
# When testing code that calls external APIs (like OpenAQ or LINE), we don't
# want to make real HTTP calls. Instead, we create a "mock" — a fake module
# that pretends to be the HTTP client but returns predetermined responses.
#
# Mox enforces that mocks follow a behaviour (interface), which means:
# 1. The mock must implement the same functions as the real module
# 2. You can't accidentally mock a function that doesn't exist
# 3. Tests are explicit about what they expect

# Define the mock module for our HTTP client.
# This creates a module called `CmAqi.HttpClient.Mock` that implements
# all the callbacks defined in `CmAqi.HttpClient` behaviour.
Mox.defmock(CmAqi.HttpClient.Mock, for: CmAqi.HttpClient)
