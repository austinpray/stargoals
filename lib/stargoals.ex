defmodule Stargoals do
  alias Stargoals.StarKeeper
  alias Stargoals.GitHub
  alias Stargoals.Chat
  use Application

  def start(_type, _args) do
    {:ok, bucket} = StarKeeper.start_link
    StarKeeper.put(bucket, :interval, :timer.minutes(1))
    Task.start_link(fn -> loop(bucket) end)
    {:ok, self()}
  end

  def get_stars(bucket) do
    StarKeeper.get(bucket, :stars)
  end

  def set_stars(bucket, stars) do
    StarKeeper.put(bucket, :stars, stars)
  end

  def get_gh_client(bucket) do
    StarKeeper.get(bucket, :gh)
  end

  @doc ~S"""
  Parses GitHub repo response and sums the stars

  ## Example
      iex> Stargoals.calc_stars([%{stargazers_count: 1}, %{stargazers_count: 2}])
      3
  """
  def calc_stars(repos) do
    List.foldl(repos, 0, fn(el, acc) -> Dict.get(el, "stargazers_count", 0) + acc end)
  end

  def loop(bucket) do
    stars = fn -> get_stars(bucket) end
    next = fn -> loop(bucket) end
    interval = fn -> StarKeeper.get(bucket, :interval) end

    prevStars = stars.()

    case GitHub.get("/orgs/roots/repos") do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
        body
        |> calc_stars
        |> (fn(n) -> set_stars(bucket, n) end).()
      {:error, %HTTPoison.Error{reason: reason}} ->
        IO.inspect reason
    end

    starCountIsInteresting = Chat.getting_close? stars.(), 10000
    starCountHasChanged = prevStars !== stars.()

    if starCountIsInteresting && starCountHasChanged do
      Chat.get_message stars.(), 10000
      |> Chat.send_to_slack
    end
    # TODO: add hourly checkin
    IO.puts("Current Star Count: " <> to_string(stars.()))
    :timer.sleep(interval.())
    next.()
  end
end

defmodule Stargoals.Chat do
  @doc ~S"""
  Chats the correct message for a goal

  ## Examples
      iex> Stargoals.Chat.get_message 9999, 10000
      "1 more star to go!"

      iex> Stargoals.Chat.get_message 9998, 10000
      "2 more stars to go!"

      iex> Stargoals.Chat.get_message 10000, 10000
      "YOU REACHED 10000 STARS"
  """
  def get_message(starCount, goalCount) do
    remaining = goalCount - starCount
    starsWord = remaining > 1 && "stars" || "star"
    if remaining === 0 do
      "YOU REACHED #{goalCount} STARS"
    else
      "#{goalCount - starCount} more #{starsWord} to go!"
    end
  end

  @doc ~S"""
  Are we there yet?

  ## Examples 
      Interesting if in the 99th percentile
      iex> Stargoals.Chat.getting_close? 9975, 10000
      true

      iex> Stargoals.Chat.getting_close? 10000, 10000
      true

      Uninteresting
      iex> Stargoals.Chat.getting_close? 8000, 10000
      false

      iex> Stargoals.Chat.getting_close? 10001, 10000
      false
  """
  def getting_close?(starCount, goalCount) do
    interesting = starCount >= (goalCount * 0.9975) && starCount <= goalCount
  end

  defp webhook do
    System.get_env("SLACK_WEBHOOK") || Application.get_env(:stargoals, :slack_webhook)
  end

  @doc ~S"""
  Sends a message to slack
  
  ## Examples
      iex> Stargoals.Chat.send_to_slack("Yo").status_code
      200
  """
  def send_to_slack(message) do
    payload = Poison.encode!(%{text: message})
    HTTPoison.post!(webhook, payload)
  end
end

defmodule Stargoals.StarKeeper do
  def start_link do
    Agent.start_link(fn -> HashDict.new end)
  end

  @doc """
  Gets a value from the `bucket` by `key`.
  """
  def get(bucket, key) do
    Agent.get(bucket, &HashDict.get(&1, key))
  end

  @doc """
  Puts the `value` for the given `key` in the `bucket`.
  """
  def put(bucket, key, value) do
    Agent.update(bucket, &HashDict.put(&1, key, value))
  end

end

defmodule Stargoals.GitHub do
  use HTTPoison.Base

  defp secret_key do
    System.get_env("GH_TOKEN") || Application.get_env(:stargoals, :gh_token)
  end

  def process_request_headers(headers) do
    Dict.put headers, :Authorization, "token #{secret_key}"
  end

  def process_url(url) do
    "https://api.github.com" <> url
  end

  def process_response_body(body) do
    body
    |> Poison.Parser.parse!
  end
end
