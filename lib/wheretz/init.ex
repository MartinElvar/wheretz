defmodule WhereTZ.Init do
  require Logger

  def run() do
    :mnesia.stop()
    :mnesia.create_schema([node()])
    :ok = :mnesia.start()

    already_exists = :geo in :mnesia.system_info(:local_tables)

    if !already_exists do
      create_database()
      download_and_parse_data()
    end
  end

  def create_database() do
    Logger.info("Setting up database")

    {:atomic, :ok} =
      :mnesia.create_table(:geo,
        attributes: [:zone_name, :minx, :maxx, :miny, :maxy, :geo_object],
        disc_only_copies: [node()]
      )

    :mnesia.add_table_index(:geo, :minx)
    :mnesia.add_table_index(:geo, :maxx)
    :mnesia.add_table_index(:geo, :miny)
    :mnesia.add_table_index(:geo, :maxy)
  end

  def download_and_parse_data do
    if !File.exists?(Application.app_dir(:wheretz, "priv/data")) do
      download_data()
    end

    load_and_insert_json()
  end

  def download_data() do
    priv_data_path = Application.app_dir(:wheretz, "priv/data")
    Logger.info("priv_data_path =#{inspect(priv_data_path)}")
    File.mkdir(priv_data_path)

    link =
      "https://github.com/evansiroky/timezone-boundary-builder/releases/download/2023b/timezones-with-oceans.geojson.zip"

    Logger.info("Download #{inspect(link)} ...")
    %HTTPoison.Response{body: body} = HTTPoison.get!(link, [], follow_redirect: true)
    Logger.info("Save to file")
    File.write!(priv_data_path <> "/timezones-with-oceans.geojson.zip", body)

    Logger.info("Unzip ...")

    :zip.unzip(String.to_charlist(priv_data_path) ++ ~c"/timezones-with-oceans.geojson.zip", [
      {:cwd, String.to_charlist(priv_data_path)}
    ])
  end

  def load_and_insert_json() do
    Logger.info("Parsing & inserting json ...")
    priv_data_path = Application.app_dir(:wheretz, "priv/data")

    File.stream!(priv_data_path <> "/combined-with-oceans.json", [], 20000)
    |> Jaxon.Stream.from_enumerable()
    |> Jaxon.Stream.query([:root, "features", :all])
    |> Stream.map(&parse_item/1)
    |> Stream.map(&insert_item/1)
    |> Stream.run()

    Logger.info("Ready")
  end

  def parse_item(item) do
    {minx, maxx, miny, maxy} = bounding_box(item["geometry"])
    zone_name = item["properties"]["tzid"]
    geo_object = item |> Geo.JSON.decode!()
    {zone_name, minx, maxx, miny, maxy, geo_object}
  end

  def insert_item(item) do
    {zone_name, minx, maxx, miny, maxy, geo_object} = item
    Logger.info("Add zone #{inspect(zone_name)}")
    :mnesia.dirty_write({:geo, zone_name, minx, maxx, miny, maxy, geo_object})
  end

  def bounding_box(%{"type" => "Polygon"} = geometry),
    do: bounding_box(geometry, :polygon)

  def bounding_box(%{"type" => "MultiPolygon"} = geometry),
    do: bounding_box(geometry, :multi_polygon)

  def bounding_box(geometry, :polygon) do
    li =
      geometry["coordinates"]
      |> Enum.reduce([], &(&1 ++ &2))

    [minx, _] = Enum.min_by(li, fn [x, _y] -> x end)
    [maxx, _] = Enum.max_by(li, fn [x, _y] -> x end)
    [_, miny] = Enum.min_by(li, fn [_x, y] -> y end)
    [_, maxy] = Enum.max_by(li, fn [_x, y] -> y end)

    {minx, maxx, miny, maxy}
  end

  def bounding_box(geometry, :multi_polygon) do
    li =
      geometry["coordinates"]
      |> Enum.reduce([], &(&1 ++ &2))
      |> Enum.reduce([], &(&1 ++ &2))

    [minx, _] = Enum.min_by(li, fn [x, _y] -> x end)
    [maxx, _] = Enum.max_by(li, fn [x, _y] -> x end)
    [_, miny] = Enum.min_by(li, fn [_x, y] -> y end)
    [_, maxy] = Enum.max_by(li, fn [_x, y] -> y end)

    {minx, maxx, miny, maxy}
  end
end
