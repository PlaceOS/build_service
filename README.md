# PlaceOS Build Driver Service

[PlaceOS](https://place.technology/) service for compiling and storing PlaceOS drivers. 

## Contributing

See [`CONTRIBUTING.md`](./CONTRIBUTING.md).


## Testing

`crystal spec`

* to run in development mode `crystal ./src/app.cr`

## Compiling

`crystal build ./src/app.cr`

### Deploying

Once compiled you are left with a binary `./app`

* for help `./app --help`
* viewing routes `./app --routes`
* run on a different port or host `./app -b 0.0.0.0 -p 80`
