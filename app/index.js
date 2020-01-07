const express = require('express')
const { Storage } = require('@google-cloud/storage')
const app = express()

const storage = new Storage()
const bucketName = process.env.BUCKET_NAME

app.get('/', (req, res) => {
  res.send('This is an example application')
})

app.get('/list', async (req, res) => {
  const [files] = await storage.bucket(bucketName).getFiles()
  res.send({
    files: files.map(file => file.name)
  })
})

app.get('/test', (req, res) => {
  storage.bucket(bucketName).file('test.txt').createReadStream()
    .on('error', err => {
      console.error('Got error while reading file.')
      console.error(err)
      res.status(500).send(`Could not read file, got error: ${JSON.stringify(err)}`)
    })
    .pipe(res)
})

app.post('/test', (req, res) => {
  const file = storage.bucket(bucketName).file('test.txt')
  req
    .pipe(file.createWriteStream())
    .on('error', err => {
      console.error('Got error while writing file.')
      console.error(err)
      res.status(500).send(`Could not write file, got exception: ${JSON.stringify(err)}`)
    })
    .on('finish', () => {
      res.sendStatus(204)
    })
})

const port = process.env.PORT || 8080
app.listen(port, () => {
  console.log(`Listening on port ${port}`)
})
